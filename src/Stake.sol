// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {LPToken} from "./ERC20Tokens/LPToken.sol";
import {nQToken} from "./ERC20Tokens/nQToken.sol";
import {MockRewardOracle} from "./Oracles/MockRewardOracle.sol";
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
    MockRewardOracle public immutable i_rewardOracle;

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
        i_rewardOracle = MockRewardOracle(_rewardOracle);
        i_owners = _owners;
        signaturesRequired = _signaturesRequired;
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

        // Pull tokens from caller — requires prior approve()
        bool ok = i_lpToken.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        userToTokenAmount[msg.sender] += amount;
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
        if (!success) revert TransferFailed();

        emit ethWithdrawnEvent(msg.sender, amount, 0);
    }

    /// @notice Withdraw staked LPToken after cooldown has passed.
    function withdrawToken(uint256 amount) external nonReentrancyGuard requiredNotSuspicious {
        if (withdrawRequested[msg.sender] == 0) revert WithdrawalRequestNotFound();
        if (block.timestamp - withdrawRequested[msg.sender] < 2 days) revert StakeStillLocked();
        if (userToTokenAmount[msg.sender] < amount) revert InsufficientBalance();

        // Effects before Interactions (CEI pattern)
        userToTokenAmount[msg.sender] -= amount;
        if (userToEthAmount[msg.sender] == 0 && userToTokenAmount[msg.sender] == 0) {
            withdrawRequested[msg.sender] = 0;
        }

        // Fetch rate in Solidity (external calls not possible inside assembly)
        uint256 rate = i_rewardOracle.getRewardRate();

        // Overflow-safe multiply then divide via Yul
        uint256 rewardAmount;
        assembly {
            // Overflow check: if rate > 0 and (amount * rate) / rate != amount, overflow occurred
            let product := mul(amount, rate)
            if and(gt(rate, 0), iszero(eq(div(product, rate), amount))) {
                revert(0, 0)
            }
            rewardAmount := div(product, 100)
        }

        bool ok = i_lpToken.transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();
        bool ok2 = i_nqToken.transfer(msg.sender, rewardAmount);
        if (!ok2) revert TransferFailed();

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
        if (value == 0) revert AmountMustBeGreaterThanZero();
        if (userToTokenAmount[from] != 0) revert AlreadyStaked();

        userToTokenAmount[from] += value;
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

    function _collectSignature(address _user, bool action) internal returns (bool) {
        if (signaturesCollected[_user][action][msg.sender]) revert AlreadySigned();
        signaturesCollected[_user][action][msg.sender] = true;
        for (uint256 i = 0; i < signaturesRequired; i++) {
            if (!signaturesCollected[_user][action][i_owners[i]]) {
                return false;
            }
        }
        for (uint256 i = 0; i < signaturesRequired; i++) {
            signaturesCollected[_user][action][i_owners[i]] = false;
        }
        return true;
    }

}
