pragma solidity ^0.4.13;

import 'reporting/IMarket.sol';
import 'libraries/DelegationTarget.sol';
import 'libraries/Typed.sol';
import 'libraries/Initializable.sol';
import 'libraries/Ownable.sol';
import 'reporting/IUniverse.sol';
import 'reporting/IReportingToken.sol';
import 'reporting/IReputationToken.sol';
import 'reporting/IDisputeBond.sol';
import 'trading/ICash.sol';
import 'trading/IShareToken.sol';
import 'extensions/MarketExtensions.sol';
import 'extensions/MarketFeeCalculator.sol';
import 'factories/ShareTokenFactory.sol';
import 'factories/ReportingTokenFactory.sol';
import 'factories/DisputeBondTokenFactory.sol';
import 'libraries/token/ERC20Basic.sol';
import 'libraries/math/SafeMathUint256.sol';
import 'libraries/math/SafeMathInt256.sol';
import 'reporting/Reporting.sol';


contract Market is DelegationTarget, Typed, Initializable, Ownable, IMarket {
    using SafeMathUint256 for uint256;
    using SafeMathInt256 for int256;

    uint256 private numTicks;
    uint256 private feePerEthInAttoeth;

    uint256 private constant MAX_FEE_PER_ETH_IN_ATTOETH = 5 * 10 ** 17;
    uint256 private constant APPROVAL_AMOUNT = 2 ** 254;
    address private constant NULL_ADDRESS = address(0);

    IReportingWindow private reportingWindow;
    uint256 private endTime;
    uint8 private numOutcomes;
    uint256 private marketCreationBlock;
    address private designatedReporterAddress;
    mapping(bytes32 => IReportingToken) private reportingTokens;
    ICash private cash;
    IShareToken[] private shareTokens;
    uint256 private finalizationTime;
    uint256 private designatedReportReceivedTime;
    bytes32 private tentativeWinningPayoutDistributionHash;
    // We keep track of the second place winning payout hash since when a dispute bond is placed it counts negatively toward stake and we can't otherwise figure out which outcome to promote. Since we only store two hashes it may be the case that if promotion occurs this value is not actually second place, but there is only one case where promotion occurs in a market's lifetime, so it will no longer be relevant at that point.
    bytes32 private bestGuessSecondPlaceTentativeWinningPayoutDistributionHash;
    bytes32 private finalPayoutDistributionHash;
    IDisputeBond private designatedReporterDisputeBondToken;
    IDisputeBond private limitedReportersDisputeBondToken;
    IDisputeBond private allReportersDisputeBondToken;
    uint256 private validityBondAttoeth;
    uint256 private designatedReporterBondAttoeth;

    /**
     * @dev Makes the function trigger a migration before execution
     */
    modifier triggersMigration() {
        migrateThroughAllForks();
        _;
    }

    function initialize(IReportingWindow _reportingWindow, uint256 _endTime, uint8 _numOutcomes, uint256 _numTicks, uint256 _feePerEthInAttoeth, ICash _cash, address _creator, address _designatedReporterAddress) public payable beforeInitialized returns (bool _success) {
        endInitialization();
        require(address(_reportingWindow) != NULL_ADDRESS);
        require(_numOutcomes >= 2);
        require(_numOutcomes <= 8);
        require((_numTicks.isMultipleOf(_numOutcomes)));
        require(feePerEthInAttoeth <= MAX_FEE_PER_ETH_IN_ATTOETH);
        require(_creator != NULL_ADDRESS);
        require(_cash.getTypeName() == "Cash");
        // FIXME: require market to be on a non-forking universe; repeat this check up the stack as well if necessary (e.g., in reporting window)
        // CONSIDER: should we allow creator to send extra ETH, is there risk of variability in bond requirements?
        require(msg.value == MarketFeeCalculator(controller.lookup("MarketFeeCalculator")).getMarketCreationCost(_reportingWindow));
        reportingWindow = _reportingWindow;
        endTime = _endTime;
        numOutcomes = _numOutcomes;
        numTicks = _numTicks;
        feePerEthInAttoeth = _feePerEthInAttoeth;
        marketCreationBlock = block.number;
        designatedReporterAddress = _designatedReporterAddress;
        cash = _cash;
        owner = _creator;
        for (uint8 _outcome = 0; _outcome < numOutcomes; _outcome++) {
            shareTokens.push(createShareToken(_outcome));
        }
        approveSpenders();
        return true;

        // TODO: we need to update this signature (and all of the places that call it) to allow the creator (UI) to pass in a number of other things which will all be logged here
        // TODO: log short description
        // TODO: log long description
        // TODO: log min display price
        // TODO: log max display price
        // TODO: log tags (0-2)
        // TODO: log outcome labels (same number as numOutcomes)
        // TODO: log type (scalar, binary, categorical)
        // TODO: log any immutable data associated with the market (e.g., endTime, numOutcomes, numTicks, cash address, etc.)
    }

    function createShareToken(uint8 _outcome) private returns (IShareToken) {
        return ShareTokenFactory(controller.lookup("ShareTokenFactory")).createShareToken(controller, this, _outcome);
    }

    // this will need to be called manually for each open market if a spender contract is updated
    function approveSpenders() private returns (bool) {
        bytes32[5] memory _names = [bytes32("CancelOrder"), bytes32("CompleteSets"), bytes32("FillOrder"), bytes32("TradingEscapeHatch"), bytes32("ClaimProceeds")];
        for (uint8 i = 0; i < _names.length; i++) {
            cash.approve(controller.lookup(_names[i]), APPROVAL_AMOUNT);
        }
        for (uint8 j = 0; j < numOutcomes; j++) {
            shareTokens[j].approve(controller.lookup("FillOrder"), APPROVAL_AMOUNT);
        }
        return true;
    }

    function decreaseMarketCreatorSettlementFeeInAttoethPerEth(uint256 _newFeePerEthInWei) public onlyOwner returns (bool) {
        require(_newFeePerEthInWei < feePerEthInAttoeth);
        feePerEthInAttoeth = _newFeePerEthInWei;
        return true;
    }

    function designatedReport(uint256[] _payoutNumerators) public returns (bool) {
        // intentionally does not migrate the market as designated report markets won't actually migrate unless a dispute bond has been placed or the designated report doesn't occur
        require(msg.sender == designatedReporterAddress);
        require(getReportingState() == ReportingState.DESIGNATED_REPORTING);
        // we have to create the reporting token so the rest of the system works (winning reporting token must exist)
        getReportingToken(_payoutNumerators);
        designatedReportReceivedTime = block.timestamp;
        tentativeWinningPayoutDistributionHash = derivePayoutDistributionHash(_payoutNumerators);
        reportingWindow.updateMarketPhase();
        return true;
    }

    function disputeDesignatedReport() public triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.DESIGNATED_DISPUTE);
        designatedReporterDisputeBondToken = DisputeBondTokenFactory(controller.lookup("DisputeBondTokenFactory")).createDisputeBondToken(controller, this, msg.sender, Reporting.designatedReporterDisputeBondAmount(), tentativeWinningPayoutDistributionHash);
        reportingWindow.getReputationToken().trustedTransfer(msg.sender, designatedReporterDisputeBondToken, Reporting.designatedReporterDisputeBondAmount());
        updateTentativeWinningPayoutDistributionHash(tentativeWinningPayoutDistributionHash);
        reportingWindow.updateMarketPhase();
        return true;
    }

    function disputeLimitedReporters() public triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.LIMITED_DISPUTE);
        limitedReportersDisputeBondToken = DisputeBondTokenFactory(controller.lookup("DisputeBondTokenFactory")).createDisputeBondToken(controller, this, msg.sender, Reporting.limitedReportersDisputeBondAmount(), tentativeWinningPayoutDistributionHash);
        reportingWindow.getReputationToken().trustedTransfer(msg.sender, limitedReportersDisputeBondToken, Reporting.limitedReportersDisputeBondAmount());
        IReportingWindow _newReportingWindow = getUniverse().getNextReportingWindow();
        updateTentativeWinningPayoutDistributionHash(tentativeWinningPayoutDistributionHash);
        return migrateReportingWindow(_newReportingWindow);
    }

    function disputeAllReporters() public triggersMigration returns (bool) {
        require(getReportingState() == ReportingState.ALL_DISPUTE);
        allReportersDisputeBondToken = DisputeBondTokenFactory(controller.lookup("DisputeBondTokenFactory")).createDisputeBondToken(controller, this, msg.sender, Reporting.allReportersDisputeBondAmount(), tentativeWinningPayoutDistributionHash);
        reportingWindow.getReputationToken().trustedTransfer(msg.sender, allReportersDisputeBondToken, Reporting.allReportersDisputeBondAmount());
        reportingWindow.getUniverse().fork();
        IReportingWindow _newReportingWindow = getUniverse().getReportingWindowForForkEndTime();
        updateTentativeWinningPayoutDistributionHash(tentativeWinningPayoutDistributionHash);
        return migrateReportingWindow(_newReportingWindow);
    }

    function migrateReportingWindow(IReportingWindow _newReportingWindow) private afterInitialized returns (bool) {
        _newReportingWindow.migrateMarketInFromSibling();
        reportingWindow.removeMarket();
        reportingWindow = _newReportingWindow;
        reportingWindow.updateMarketPhase();
        return true;
    }

    function updateTentativeWinningPayoutDistributionHash(bytes32 _payoutDistributionHash) public returns (bool) {
        int256 _tentativeWinningStake = getPayoutDistributionHashStake(tentativeWinningPayoutDistributionHash);
        int256 _secondPlaceStake = getPayoutDistributionHashStake(bestGuessSecondPlaceTentativeWinningPayoutDistributionHash);
        int256 _payoutStake = getPayoutDistributionHashStake(_payoutDistributionHash);

        if (_tentativeWinningStake >= _secondPlaceStake && _secondPlaceStake >= _payoutStake) {
            tentativeWinningPayoutDistributionHash = (_tentativeWinningStake > 0) ? tentativeWinningPayoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_secondPlaceStake > 0) ? bestGuessSecondPlaceTentativeWinningPayoutDistributionHash : bytes32(0);
        } else if (_tentativeWinningStake >= _payoutStake && _payoutStake >= _secondPlaceStake) {
            tentativeWinningPayoutDistributionHash = (_tentativeWinningStake > 0) ? tentativeWinningPayoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_payoutStake > 0) ? _payoutDistributionHash : bytes32(0);
        } else if (_secondPlaceStake >= _tentativeWinningStake && _tentativeWinningStake >= _payoutStake) {
            tentativeWinningPayoutDistributionHash = (_secondPlaceStake > 0) ? bestGuessSecondPlaceTentativeWinningPayoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_tentativeWinningStake > 0) ? tentativeWinningPayoutDistributionHash: bytes32(0);
        } else if (_secondPlaceStake >= _payoutStake && _payoutStake >= _tentativeWinningStake) {
            tentativeWinningPayoutDistributionHash = (_secondPlaceStake > 0) ? bestGuessSecondPlaceTentativeWinningPayoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_payoutStake > 0) ? _payoutDistributionHash: bytes32(0);
        } else if (_payoutStake >= _tentativeWinningStake && _tentativeWinningStake >= _secondPlaceStake) {
            tentativeWinningPayoutDistributionHash = (_payoutStake > 0) ? _payoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_tentativeWinningStake > 0) ? tentativeWinningPayoutDistributionHash: bytes32(0);
        } else if (_payoutStake >= _secondPlaceStake && _secondPlaceStake >= _tentativeWinningStake) {
            tentativeWinningPayoutDistributionHash = (_payoutStake > 0) ? _payoutDistributionHash: bytes32(0);
            bestGuessSecondPlaceTentativeWinningPayoutDistributionHash = (_secondPlaceStake > 0) ? bestGuessSecondPlaceTentativeWinningPayoutDistributionHash: bytes32(0);
        }

        return true;
    }

    function getPayoutDistributionHashStake(bytes32 _payoutDistributionHash) public constant returns (int256) {
        if (_payoutDistributionHash == bytes32(0)) {
            return 0;
        }

        IReportingToken _reportingToken = reportingTokens[_payoutDistributionHash];
        if (address(_reportingToken) == NULL_ADDRESS) {
            return 0;
        }

        int256 _payoutStake = int256(_reportingToken.totalSupply());

        if (address(designatedReporterDisputeBondToken) != NULL_ADDRESS) {
            if (designatedReporterDisputeBondToken.getDisputedPayoutDistributionHash() == _payoutDistributionHash) {
                _payoutStake -= int256(Reporting.designatedReporterDisputeBondAmount());
            }
        }
        if (address(limitedReportersDisputeBondToken) != NULL_ADDRESS) {
            if (limitedReportersDisputeBondToken.getDisputedPayoutDistributionHash() == _payoutDistributionHash) {
                _payoutStake -= int256(Reporting.limitedReportersDisputeBondAmount());
            }
        }
        if (address(allReportersDisputeBondToken) != NULL_ADDRESS) {
            if (allReportersDisputeBondToken.getDisputedPayoutDistributionHash() == _payoutDistributionHash) {
                _payoutStake -= int256(Reporting.allReportersDisputeBondAmount());
            }
        }

        return _payoutStake;
    }

    function tryFinalize() public returns (bool) {
        if (getReportingState() != ReportingState.AWAITING_FINALIZATION) {
            return false;
        }

        if (getUniverse().getForkingMarket() == this) {
            tentativeWinningPayoutDistributionHash = getWinningPayoutDistributionHashFromFork();
        }

        require(tentativeWinningPayoutDistributionHash != bytes32(0));

        finalPayoutDistributionHash = tentativeWinningPayoutDistributionHash;
        finalizationTime = block.timestamp;
        transferIncorrectDisputeBondsToWinningReportingToken();
        reportingWindow.updateMarketPhase();
        return true;

        // FIXME: when the market is finalized, we need to add `reportingTokens[finalPayoutDistributionHash].totalSupply()` to the reporting window.  This is necessary for fee collection which is a cross-market operation.
        // TODO: figure out how to make it so fee distribution is delayed until all markets have been finalized; we can enforce it contract side and let the UI deal with the actual work
        // FIXME: if finalPayoutDistributionHash != getIdentityDistributionId(), pay back validity bond holder
        // FIXME: if finalPayoutDistributionHash == getIdentityDistributionId(), transfer validity bond to reportingWindow (reporter fee pot)
        // FIXME: if designated report is wrong, transfer designated report bond to reportingWindow
        // FIXME: if designated report is right, transfer designated report bond to market creator
    }

    function migrateDueToNoReports() public returns (bool) {
        require(getReportingState() == ReportingState.AWAITING_NO_REPORT_MIGRATION);
        IReportingWindow _newReportingWindow = getUniverse().getNextReportingWindow();
        migrateReportingWindow(_newReportingWindow);
        return false;
    }

    function migrateThroughAllForks() public returns (bool) {
        // this will loop until we run out of gas, follow forks until there are no more, or have reached an active fork (which will throw)
        while (migrateThroughOneFork()) {
            continue;
        }
        return true;
    }

    // returns 0 if no move occurs, 1 if move occurred, throws if a fork not yet resolved
    function migrateThroughOneFork() public returns (bool) {
        if (getReportingState() != ReportingState.AWAITING_FORK_MIGRATION) {
            return false;
        }
        // only proceed if the forking market is finalized
        require(reportingWindow.isForkingMarketFinalized());
        IUniverse _currentUniverse = getUniverse();
        // follow the forking market to its universe and then attach to the next reporting window on that universe
        bytes32 _winningForkPayoutDistributionHash = _currentUniverse.getForkingMarket().getFinalPayoutDistributionHash();
        IUniverse _destinationUniverse = _currentUniverse.getOrCreateChildUniverse(_winningForkPayoutDistributionHash);
        endTime = block.timestamp;
        IReportingWindow _newReportingWindow = _destinationUniverse.getReportingWindowByMarketEndTime(endTime, designatedReporterAddress != NULL_ADDRESS);
        _newReportingWindow.migrateMarketInFromNibling();
        reportingWindow.removeMarket();
        reportingWindow = _newReportingWindow;
        reportingWindow.updateMarketPhase();
        // reset to designated reporting
        designatedReportReceivedTime = 0;
        limitedReportersDisputeBondToken = IDisputeBond(0);
        allReportersDisputeBondToken = IDisputeBond(0);
        tentativeWinningPayoutDistributionHash = bytes32(0);
        return true;
    }

    //
    // Helpers
    //

    function getReportingToken(uint256[] _payoutNumerators) public returns (IReportingToken) {
        bytes32 _payoutDistributionHash = derivePayoutDistributionHash(_payoutNumerators);
        IReportingToken _reportingToken = reportingTokens[_payoutDistributionHash];
        if (address(_reportingToken) == NULL_ADDRESS) {
            _reportingToken = ReportingTokenFactory(controller.lookup("ReportingTokenFactory")).createReportingToken(controller, this, _payoutNumerators);
            reportingTokens[_payoutDistributionHash] = _reportingToken;
        }
        return _reportingToken;
    }

    function transferIncorrectDisputeBondsToWinningReportingToken() private returns (bool) {
        require(getReportingState() == ReportingState.FINALIZED);
        IReputationToken _reputationToken = reportingWindow.getReputationToken();
        if (getUniverse().getForkingMarket() == this) {
            return true;
        }
        if (address(designatedReporterDisputeBondToken) != NULL_ADDRESS && designatedReporterDisputeBondToken.getDisputedPayoutDistributionHash() == finalPayoutDistributionHash) {
            _reputationToken.trustedTransfer(designatedReporterDisputeBondToken, getFinalWinningReportingToken(), _reputationToken.balanceOf(designatedReporterDisputeBondToken));
        }
        if (address(limitedReportersDisputeBondToken) != NULL_ADDRESS && limitedReportersDisputeBondToken.getDisputedPayoutDistributionHash() == finalPayoutDistributionHash) {
            _reputationToken.trustedTransfer(limitedReportersDisputeBondToken, getFinalWinningReportingToken(), _reputationToken.balanceOf(limitedReportersDisputeBondToken));
        }
        return true;
    }

    function derivePayoutDistributionHash(uint256[] _payoutNumerators) public constant returns (bytes32) {
        uint256 _sum = 0;
        for (uint8 i = 0; i < _payoutNumerators.length; i++) {
            require(_payoutNumerators[i] <= numTicks);
            _sum = _sum.add(_payoutNumerators[i]);
        }
        require(_sum == numTicks);
        return sha3(_payoutNumerators);
    }

    function getReportingTokenOrZeroByPayoutDistributionHash(bytes32 _payoutDistributionHash) public constant returns (IReportingToken) {
        return reportingTokens[_payoutDistributionHash];
    }

    //
    //Getters
    //

    function getTypeName() public constant returns (bytes32) {
        return "Market";
    }

    function getReportingWindow() public constant returns (IReportingWindow) {
        return reportingWindow;
    }

    function getUniverse() public constant returns (IUniverse) {
        return reportingWindow.getUniverse();
    }

    function getDesignatedReporterDisputeBondToken() public constant returns (IDisputeBond) {
        return designatedReporterDisputeBondToken;
    }

    function getLimitedReportersDisputeBondToken() public constant returns (IDisputeBond) {
        return limitedReportersDisputeBondToken;
    }

    function getAllReportersDisputeBondToken() public constant returns (IDisputeBond) {
        return allReportersDisputeBondToken;
    }

    function getNumberOfOutcomes() public constant returns (uint8) {
        return numOutcomes;
    }

    function getEndTime() public constant returns (uint256) {
        return endTime;
    }

    function getTentativeWinningPayoutDistributionHash() public constant returns (bytes32) {
        return tentativeWinningPayoutDistributionHash;
    }

    function getFinalWinningReportingToken() public constant returns (IReportingToken) {
        return reportingTokens[finalPayoutDistributionHash];
    }

    function getShareToken(uint8 _outcome)  public constant returns (IShareToken) {
        require(_outcome < numOutcomes);
        return shareTokens[_outcome];
    }

    function getFinalPayoutDistributionHash() public constant returns (bytes32) {
        return finalPayoutDistributionHash;
    }

    function getNumTicks() public constant returns (uint256) {
        return numTicks;
    }

    function getDenominationToken() public constant returns (ICash) {
        return cash;
    }

    function getMarketCreatorSettlementFeeInAttoethPerEth() public constant returns (uint256) {
        return feePerEthInAttoeth;
    }

    function getFinalizationTime() public constant returns (uint256) {
        return finalizationTime;
    }

    function isContainerForReportingToken(Typed _shadyTarget) public constant returns (bool) {
        if (_shadyTarget.getTypeName() != "ReportingToken") {
            return false;
        }
        IReportingToken _shadyReportingToken = IReportingToken(_shadyTarget);
        bytes32 _shadyId = _shadyReportingToken.getPayoutDistributionHash();
        IReportingToken _reportingToken = reportingTokens[_shadyId];
        return _reportingToken == _shadyReportingToken;
    }

    function isContainerForShareToken(Typed _shadyTarget) public constant returns (bool) {
        if (_shadyTarget.getTypeName() != "ShareToken") {
            return false;
        }
        IShareToken _shadyShareToken = IShareToken(_shadyTarget);
        return getShareToken(_shadyShareToken.getOutcome()) == _shadyShareToken;
    }

    function isContainerForDisputeBondToken(Typed _shadyTarget) public constant returns (bool) {
        if (_shadyTarget.getTypeName() != "DisputeBondToken") {
            return false;
        }
        IDisputeBond _shadyDisputeBond = IDisputeBond(_shadyTarget);
        if (designatedReporterDisputeBondToken == _shadyDisputeBond) {
            return true;
        }
        if (limitedReportersDisputeBondToken == _shadyDisputeBond) {
            return true;
        }
        if (allReportersDisputeBondToken == _shadyDisputeBond) {
            return true;
        }
        return false;
    }

    function getDesignatedReportDueTimestamp() public constant returns (uint256) {
        if (designatedReportReceivedTime != 0) {
            return designatedReportReceivedTime;
        }
        return endTime + Reporting.designatedReportingDurationSeconds();
    }

    function getDesignatedReportDisputeDueTimestamp() public constant returns (uint256) {
        return getDesignatedReportDueTimestamp() + Reporting.designatedReportingDisputeDurationSeconds();
    }

    function getReportingState() public constant returns (ReportingState) {
        // This market has been finalized
        if (finalPayoutDistributionHash != bytes32(0)) {
            return ReportingState.FINALIZED;
        }

        // If there is an active fork we need to migrate
        IMarket _forkingMarket = getUniverse().getForkingMarket();
        if (address(_forkingMarket) != NULL_ADDRESS && _forkingMarket != this) {
            return ReportingState.AWAITING_FORK_MIGRATION;
        }

        // Before trading in the market is finished
        if (block.timestamp < endTime) {
            return ReportingState.PRE_REPORTING;
        }

        // Designated reporting period has not passed yet
        if (block.timestamp < getDesignatedReportDueTimestamp()) {
            return ReportingState.DESIGNATED_REPORTING;
        }

        bool _designatedReportDisputed = address(designatedReporterDisputeBondToken) != NULL_ADDRESS;
        bool _limitedReportDisputed = address(limitedReportersDisputeBondToken) != NULL_ADDRESS;

        // If we have a designated report that hasn't been disputed it is either in the dispute window or we can finalize the market
        if (designatedReportReceivedTime != 0 && !_designatedReportDisputed) {
            bool _beforeDesignatedDisputeDue = block.timestamp < getDesignatedReportDisputeDueTimestamp();
            return _beforeDesignatedDisputeDue ? ReportingState.DESIGNATED_DISPUTE : ReportingState.AWAITING_FINALIZATION;
        }

        // If this market is the one forking we are in the process of migration or we're ready to finalize
        if (_forkingMarket == this) {
            if (getWinningPayoutDistributionHashFromFork() != bytes32(0)) {
                return ReportingState.AWAITING_FINALIZATION;
            }
            return ReportingState.FORKING;
        }

        bool _reportingWindowOver = block.timestamp > reportingWindow.getEndTime();

        if (_reportingWindowOver) {
            if (tentativeWinningPayoutDistributionHash == bytes32(0)) {
                return ReportingState.AWAITING_NO_REPORT_MIGRATION;
            }
            return ReportingState.AWAITING_FINALIZATION;
        }

        // If a limited dispute bond has been posted we are in some phase of all reporting depending on time
        if (_limitedReportDisputed) {
            if (reportingWindow.isDisputeActive()) {
                if (tentativeWinningPayoutDistributionHash == bytes32(0)) {
                    return ReportingState.AWAITING_NO_REPORT_MIGRATION;
                } else {
                    return ReportingState.ALL_DISPUTE;
                }
            }
            return ReportingState.ALL_REPORTING;
        }

        // Either no designated report was made or the designated report was disputed so we are in some phase of limited reporting
        if (reportingWindow.isDisputeActive()) {
            if (tentativeWinningPayoutDistributionHash == bytes32(0)) {
                return ReportingState.AWAITING_NO_REPORT_MIGRATION;
            } else {
                return ReportingState.LIMITED_DISPUTE;
            }
        }

        return ReportingState.LIMITED_REPORTING;
    }

    function getWinningPayoutDistributionHashFromFork() private returns (bytes32) {
        return MarketExtensions(controller.lookup("MarketExtensions")).getWinningPayoutDistributionHashFromFork(this);
    }
}
