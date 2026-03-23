// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {LPToken} from "./ERC20Tokens/LPToken.sol";
import {nQToken} from "./ERC20Tokens/nQToken.sol";
import {IRewardOracle} from "./Oracles/IRewardOracle.sol";
import {IERC1363Receiver} from "@openzeppelin/interfaces/IERC1363Receiver.sol";
// this is a time bound staking contract

// Structure for this contract
// State Variables
// Events
// Errors
// Modifiers
// External Functions
// Internal Functions
contract Stake is IERC1363Receiver {
    LPToken public immutable i_lpToken;
    nQToken public immutable i_nqToken;
    IRewardOracle public immutable i_rewardOracle;

    //Security multisig addresses - dynamic sized array
    address[] public i_owners;

    // ETH staking balances
    mapping(address => uint256) public userToEthAmount;
    // LPToken staking balances
    mapping(address => uint256) public userToTokenAmount;

    // Withdrawal request timestamps (shared cooldown for both asset types)
    mapping(address => uint256) public withdrawRequested;

    mapping(address => bool) public flaggedSuspicious;

    // action: true = flag, false = unflag
    mapping(address => mapping(bool => mapping(address => bool))) public signaturesCollected;

    // --- Cumulative reward accumulator ---
    // Tracks sum of (rate * deltaBlocks) since contract deployment.
    // Updated on every state-changing call so the integral is always current.
    uint256 public globalRewardIndex;
    uint256 public lastUpdateBlock;

    // Per-user snapshot of globalRewardIndex taken when they staked tokens.
    // Reward owed = userToTokenAmount[u] * (globalRewardIndex - userRewardIndex[u]) / 100
    mapping(address => uint256) public userRewardIndex;

    bool private _locked;

    uint256 public signaturesRequired;

    event ethStakedEvent(address indexed user, uint256 amount);
    event tokenStakedEvent(address indexed user, uint256 amount);
    event requestedWithdrawEvent(address indexed user, uint256 timestamp);
    event ethWithdrawnEvent(address indexed user, uint256 amount, uint256 rewardAmount);
    event tokenWithdrawnEvent(address indexed user, uint256 amount, uint256 rewardAmount);
    event flaggedSuspiciousEvent(address indexed user, address indexed flaggedBy);
    event unflagSuspiciousActivityEvent(address indexed user, address indexed unflaggedBy);

    error AlreadyStaked();
    error AmountMustBeGreaterThanZero();
    error NoActiveStake();
    error WithdrawalRequestNotFound();
    error StakeStillLocked();
    error InsufficientBalance();
    error WithdrawalAlreadyRequested();
    error TransferFailed();
    error AlreadySigned();
    error UserNotFlagged();

    modifier nonReentrancyGuard() {
        require(!_locked, "ReentrancyGuard: reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    modifier requiredMultisig() {
        bool isOwner = false;
        for (uint256 i = 0; i < i_owners.length; i++) {
            if (i_owners[i] == msg.sender) {
                isOwner = true;
                break;
            }
        }
        require(isOwner, "Not an owner");
        _;
    }

    modifier requiredNotSuspicious() {
        require(!flaggedSuspicious[msg.sender], "User is flagged as suspicious");
        _;
    }

    constructor(
        address _LPToken,
        address _nQToken,
        address _rewardOracle,
        address[] memory _owners,
        uint256 _signaturesRequired
    ) {
        require(_owners.length > 0, "No owners provided");
        require(_signaturesRequired > 0 && _signaturesRequired <= _owners.length, "Invalid signaturesRequired");
        i_lpToken = LPToken(_LPToken);
        i_nqToken = nQToken(_nQToken);
        i_rewardOracle = IRewardOracle(_rewardOracle);
        i_owners = _owners;
        signaturesRequired = _signaturesRequired;
        lastUpdateBlock = block.number;
    }

    /////////////////////////////////////////////
    // EXTERNAL FUNCTIONS //////////////////////
    /////////////////////////////////////////////

    /// @notice Stake native ETH. Send ETH along with the call.
    function stakeEth() external payable nonReentrancyGuard {
        if (msg.value == 0) revert AmountMustBeGreaterThanZero();
        if (userToEthAmount[msg.sender] != 0) revert AlreadyStaked();

        userToEthAmount[msg.sender] += msg.value;
        emit ethStakedEvent(msg.sender, msg.value);
    }

    /// @notice Stake LPToken. Caller must have approved this contract first.
    function stakeToken(uint256 amount) external nonReentrancyGuard {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (userToTokenAmount[msg.sender] != 0) revert AlreadyStaked();

        _updateGlobalIndex();

        // Pull tokens from caller — requires prior approve()
        bool ok = i_lpToken.transferFrom(msg.sender, address(this), amount);
        if (!ok) {
            revert TransferFailed();
        }

        userToTokenAmount[msg.sender] += amount;
        userRewardIndex[msg.sender] = globalRewardIndex;
        emit tokenStakedEvent(msg.sender, amount);
    }

    /// @notice Request a withdrawal. Starts the 2-day cooldown timer.
    function withdrawRequest() external nonReentrancyGuard {
        if (userToEthAmount[msg.sender] == 0 && userToTokenAmount[msg.sender] == 0)
            revert NoActiveStake();
        if (withdrawRequested[msg.sender] != 0) revert WithdrawalAlreadyRequested();

        withdrawRequested[msg.sender] = block.timestamp;
        emit requestedWithdrawEvent(msg.sender, block.timestamp);
    }

    /// @notice Withdraw staked ETH after cooldown has passed.
    function withdrawEth(uint256 amount) external nonReentrancyGuard requiredNotSuspicious{
        if (withdrawRequested[msg.sender] == 0) revert WithdrawalRequestNotFound();
        if (block.timestamp - withdrawRequested[msg.sender] < 2 days) revert StakeStillLocked();
        if (userToEthAmount[msg.sender] < amount) revert InsufficientBalance();

        // Effects before Interactions (CEI pattern)
        userToEthAmount[msg.sender] -= amount;
        if (userToEthAmount[msg.sender] == 0 && userToTokenAmount[msg.sender] == 0) {
            withdrawRequested[msg.sender] = 0;
        }

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }

        emit ethWithdrawnEvent(msg.sender, amount, 0);
    }

    /// @notice Withdraw staked LPToken after cooldown has passed.
    /// Reward = stakedAmount * sum(rate[b] for b in [stakeBlock, withdrawBlock]) / 100
    function withdrawToken(uint256 amount) external nonReentrancyGuard requiredNotSuspicious {
        if (withdrawRequested[msg.sender] == 0) {
            revert WithdrawalRequestNotFound();
        }
        if (block.timestamp - withdrawRequested[msg.sender] < 2 days) revert StakeStillLocked();
        if (userToTokenAmount[msg.sender] < amount) revert InsufficientBalance();

        _updateGlobalIndex();

        // Cumulative rate delta accumulated since user staked
        uint256 delta = globalRewardIndex - userRewardIndex[msg.sender];

        // Effects before Interactions (CEI pattern)
        userToTokenAmount[msg.sender] -= amount;
        if (userToEthAmount[msg.sender] == 0 && userToTokenAmount[msg.sender] == 0) {
            withdrawRequested[msg.sender] = 0;
        }
        // Carry forward the snapshot so partial withdrawals don't double-count
        userRewardIndex[msg.sender] = globalRewardIndex;

        // Overflow-safe multiply then divide via Yul
        // reward = amount * delta / 100
        uint256 rewardAmount;
        assembly {
            // Overflow check: if delta > 0 and (amount * delta) / delta != amount, overflow occurred
            let product := mul(amount, delta)
            if and(gt(delta, 0), iszero(eq(div(product, delta), amount))) {
                revert(0, 0)
            }
            rewardAmount := div(product, 100)
        }

        bool ok = i_lpToken.transfer(msg.sender, amount);
        if (!ok) {
            revert TransferFailed();
        }
        bool ok2 = i_nqToken.transfer(msg.sender, rewardAmount);
        if (!ok2) {
            revert TransferFailed();
        }

        emit tokenWithdrawnEvent(msg.sender, amount, rewardAmount);
    }

    /// @notice ERC-1363 callback — called by LPToken when transferAndCall is used.
    ///         Allows staking in a single transaction without a prior approve().
    function onTransferReceived(
        address, /*operator*/
        address from,
        uint256 value,
        bytes calldata /*data*/
    ) external nonReentrancyGuard returns (bytes4) {
        require(msg.sender == address(i_lpToken), "Stake: unknown token");
        if (value == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        if (userToTokenAmount[from] != 0) {
            revert AlreadyStaked();
        }

        _updateGlobalIndex();

        userToTokenAmount[from] += value;
        userRewardIndex[from] = globalRewardIndex;
        emit tokenStakedEvent(from, value);

        return IERC1363Receiver.onTransferReceived.selector;
    }

    function flagSuspiciousActivity(address _user) external requiredMultisig {
        bool reached = _collectSignature(_user, true);
        if (!reached) return;
        flaggedSuspicious[_user] = true;
        // Reset cooldown so user must wait another 2 days after being unflagged
        withdrawRequested[_user] = 0;
        emit flaggedSuspiciousEvent(_user, msg.sender);
    }

    function unflagSuspiciousActivity(address _user) external requiredMultisig {
        if (!flaggedSuspicious[_user]) revert UserNotFlagged();
        bool reached = _collectSignature(_user, false);
        if (!reached) return;
        flaggedSuspicious[_user] = false;
        emit unflagSuspiciousActivityEvent(_user, msg.sender);
    }

    /////////////////////////////////////////////
    /////// INTERNAL FUNCTIONS////////////////////
    /////////////////////////////////////////

    /// @dev Advance the global reward accumulator to the current block.
    ///      Uses the oracle's cumulative rate over [lastUpdateBlock, block.number)
    ///      so that every block's rate is captured, not just the current snapshot.
    ///      Must be called before any stake/unstake to keep the integral correct.
    function _updateGlobalIndex() internal {
        uint256 from = lastUpdateBlock;
        uint256 to = block.number;
        if (to > from) {
            globalRewardIndex += i_rewardOracle.getCumulativeRate(from, to);
            lastUpdateBlock = to;
        }
    }


    /// @dev Collect one owner's signature for a multisig action.
    ///      Returns true when any M-of-N owners (not just the first M) have signed.
    function _collectSignature(address _user, bool action) internal returns (bool) {
        if (signaturesCollected[_user][action][msg.sender]) revert AlreadySigned();
        signaturesCollected[_user][action][msg.sender] = true;

        // Count signatures from any owner in the full owner set
        uint256 count = 0;
        for (uint256 i = 0; i < i_owners.length; i++) {
            if (signaturesCollected[_user][action][i_owners[i]]) {
                count++;
            }
        }

        if (count < signaturesRequired) return false;

        // Threshold reached — reset all votes so the action can be re-triggered later
        for (uint256 i = 0; i < i_owners.length; i++) {
            signaturesCollected[_user][action][i_owners[i]] = false;
        }
        return true;
    }

}
