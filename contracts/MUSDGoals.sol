// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title MUSDGoals — goal-based savings jars for MUSD on Mezo
/// @notice Each user has their own list of goals. Funds deposited into a
///         goal are held by this contract and can only ever be withdrawn
///         by the same user who deposited them, back to that same user.
/// @dev Dependency-free by design (no external imports) so the project
///      builds fully offline. Includes a minimal IERC20 interface, safe
///      ERC-20 handling tolerant of non-standard (USDT-style) tokens that
///      return no value, and an inline reentrancy guard.
interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MUSDGoals {
    // ------------------------------------------------------------------
    // Types & storage
    // ------------------------------------------------------------------

    struct Goal {
        string name;
        uint256 target;
        uint256 saved;
        uint64 deadline;
        bool active;
    }

    /// @notice The ERC-20 token all goals in this instance are denominated
    ///         in (e.g. official MUSD, or Demo MUSD for the demo instance).
    IERC20Minimal public immutable token;

    /// @dev Goals are stored per-user. A user's goalId is simply the index
    ///      into their own array — there is no global goal registry, so by
    ///      construction nobody can address another user's goals at all.
    mapping(address => Goal[]) private _goals;

    // ------------------------------------------------------------------
    // Reentrancy guard (inline, OpenZeppelin-style semantics)
    // ------------------------------------------------------------------

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "MUSDGoals: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event GoalCreated(address indexed user, uint256 indexed goalId, string name, uint256 target, uint256 deadline);
    event Deposited(address indexed user, uint256 indexed goalId, uint256 amount, uint256 newSaved);
    event Withdrawn(address indexed user, uint256 indexed goalId, uint256 amount, uint256 newSaved);
    event GoalAchieved(address indexed user, uint256 indexed goalId);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    constructor(address token_) {
        require(token_ != address(0), "MUSDGoals: token is zero address");
        token = IERC20Minimal(token_);
    }

    // ------------------------------------------------------------------
    // Core actions
    // ------------------------------------------------------------------

    /// @notice Create a new savings goal for the caller.
    /// @param name Human-readable goal name (must be non-empty).
    /// @param target Target amount in token units (must be > 0).
    /// @param deadline Unix timestamp deadline, 0 = no deadline.
    /// @return goalId Index of the new goal in the caller's goal list.
    function createGoal(string calldata name, uint256 target, uint256 deadline) external returns (uint256 goalId) {
        require(bytes(name).length > 0, "MUSDGoals: name empty");
        require(target > 0, "MUSDGoals: target is zero");
        require(deadline <= type(uint64).max, "MUSDGoals: deadline too large");

        goalId = _goals[msg.sender].length;
        // Cast is safe: deadline <= type(uint64).max is required above.
        // forge-lint: disable-next-line(unsafe-typecast)
        _goals[msg.sender].push(
            Goal({name: name, target: target, saved: 0, deadline: uint64(deadline), active: true})
        );

        emit GoalCreated(msg.sender, goalId, name, target, deadline);
    }

    /// @notice Deposit `amount` of the token into one of the caller's goals.
    /// @dev Requires a prior ERC-20 allowance from the caller to this
    ///      contract for at least `amount`.
    function deposit(uint256 goalId, uint256 amount) external nonReentrant {
        require(amount > 0, "MUSDGoals: amount is zero");
        Goal storage goal = _goalOf(msg.sender, goalId);
        require(goal.active, "MUSDGoals: goal not active");

        bool wasAchieved = goal.saved >= goal.target;

        // Effects before interaction (checks-effects-interactions).
        goal.saved += amount;
        uint256 newSaved = goal.saved;

        // Interaction last.
        _safeTransferFrom(address(token), msg.sender, address(this), amount);

        emit Deposited(msg.sender, goalId, amount, newSaved);
        if (!wasAchieved && newSaved >= goal.target) {
            emit GoalAchieved(msg.sender, goalId);
        }
    }

    /// @notice Withdraw `amount` from one of the caller's goals, back to
    ///         the caller only. Always allowed — before or after the target
    ///         is reached, before or after any deadline. Funds stay the
    ///         user's; this contract is a jar, not a lock-up.
    function withdraw(uint256 goalId, uint256 amount) external nonReentrant {
        require(amount > 0, "MUSDGoals: amount is zero");
        Goal storage goal = _goalOf(msg.sender, goalId);
        require(amount <= goal.saved, "MUSDGoals: amount exceeds saved");

        // Effects before interaction.
        goal.saved -= amount;
        uint256 newSaved = goal.saved;

        // Interaction last; destination is hard-coded to msg.sender.
        _safeTransfer(address(token), msg.sender, amount);

        emit Withdrawn(msg.sender, goalId, amount, newSaved);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice All goals belonging to `user`; goalId = array index.
    function getGoals(address user) external view returns (Goal[] memory) {
        return _goals[user];
    }

    /// @notice Number of goals belonging to `user`.
    function goalCount(address user) external view returns (uint256) {
        return _goals[user].length;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _goalOf(address user, uint256 goalId) internal view returns (Goal storage) {
        require(goalId < _goals[user].length, "MUSDGoals: goal does not exist");
        return _goals[user][goalId];
    }

    /// @dev Safe transferFrom: succeeds if the call succeeds AND the return
    ///      data is either empty (USDT-style) or decodes to `true`.
    function _safeTransferFrom(address token_, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token_.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "MUSDGoals: transferFrom failed");
    }

    /// @dev Safe transfer: same tolerance as _safeTransferFrom.
    function _safeTransfer(address token_, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "MUSDGoals: transfer failed");
    }
}
