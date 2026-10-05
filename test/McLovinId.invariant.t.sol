// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {McLovinId} from "../src/McLovinId.sol";

/// @title Handler that drives McLovinId with random call sequences.
/// @dev Keeps a ledger model (ghost balances, ghost allowances, the set of addresses that ever held
/// tokens) and asserts, inside each handler, that every call either succeeded with the exact effect
/// the ERC-20 specification requires or reverted with the exact ERC-6093 error. Nothing in the
/// handler reverts on its own, so the suite runs with `fail-on-revert` and any unexpected revert is
/// a failure rather than a silently discarded call.
///
/// Clamped handlers steer the fuzzer into the success paths (amounts bounded by balances and
/// allowances, recipients drawn from the actor set). Unclamped handlers take raw inputs so the
/// failure paths (zero address, amount above balance, amount above allowance) are hit as well.
contract McLovinIdHandler is Test {
    McLovinId public immutable token;
    uint256 public immutable supply;

    address[] public actors;
    address[] public touched;
    mapping(address => bool) public isTouched;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public successfulTransfers;
    uint256 public successfulTransferFroms;
    uint256 public successfulApprovals;
    uint256 public expectedReverts;
    uint256 public rejectedPrivilegedCalls;

    constructor(McLovinId token_, address deployer, address[] memory others) {
        token = token_;
        supply = token_.totalSupply();
        actors.push(deployer);
        for (uint256 i; i < others.length; ++i) {
            actors.push(others[i]);
        }
        _touch(deployer);
        ghostBalance[deployer] = supply;
    }

    // ---------------------------------------------------------------- helpers

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _touch(address who) internal {
        if (!isTouched[who]) {
            isTouched[who] = true;
            touched.push(who);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ---------------------------------------------------------------- clamped

    /// @dev Transfer within the actor set, amount bounded by the sender's balance.
    function transferClamped(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _transfer(from, _actor(toSeed), amount);
    }

    /// @dev Full-amount variant: the sender moves everything it holds.
    function transferFull(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), token.balanceOf(from));
    }

    /// @dev Self-transfer variant: balance must be unchanged afterwards.
    function transferToSelf(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _transfer(from, from, amount);
    }

    /// @dev Approve within the actor set with any amount, including the infinite sentinel.
    function approveClamped(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function approveInfinite(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), type(uint256).max);
    }

    /// @dev transferFrom within the actor set, amount bounded by both balance and allowance.
    function transferFromClamped(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        amount = bound(amount, 0, _min(token.balanceOf(owner), token.allowance(owner, spender)));
        _transferFrom(spender, owner, _actor(toSeed), amount);
    }

    /// @dev Grants an allowance and spends it in one step so transferFrom's success path is reached
    /// often even when the fuzzer has not lined up an approval first.
    function approveThenTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = bound(amount, 0, token.balanceOf(owner));
        _approve(owner, spender, amount);
        _transferFrom(spender, owner, _actor(toSeed), amount);
    }

    // -------------------------------------------------------------- unclamped

    /// @dev Raw transfer: any recipient, any amount. Reverts are expected and verified exactly.
    function transferUnclamped(uint256 fromSeed, address to, uint256 amount) external {
        _transfer(_actor(fromSeed), to, amount);
    }

    /// @dev Raw approve: any spender, any amount.
    function approveUnclamped(uint256 ownerSeed, address spender, uint256 amount) external {
        _approve(_actor(ownerSeed), spender, amount);
    }

    /// @dev Raw transferFrom: any recipient, any amount, whatever allowance happens to exist.
    function transferFromUnclamped(uint256 spenderSeed, uint256 ownerSeed, address to, uint256 amount) external {
        _transferFrom(_actor(spenderSeed), _actor(ownerSeed), to, amount);
    }

    /// @dev A stranger (not in the actor set) tries to spend an actor's balance with no allowance.
    function strangerTransferFrom(address stranger, uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        if (stranger == address(0)) stranger = address(1);
        _transferFrom(stranger, owner, stranger, amount);
    }

    /// @dev Calls that a token with an admin would expose. None exists here, so every one must fail
    /// without touching state. Tried from each actor, including the deployer.
    function privilegedCall(uint256 callerSeed, uint256 which, uint256 amount) external {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "setTransfersEnabled(bool)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "seize(address)"
        ];
        address caller = _actor(callerSeed);
        address target = _actor(amount);
        bytes memory data = abi.encodeWithSignature(signatures[which % signatures.length], target, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a privileged selector was accepted");
        rejectedPrivilegedCalls++;
    }

    /// @dev The token has no receive or fallback; ether sent to it must bounce.
    function sendEther(uint256 fromSeed, uint256 value) external {
        address from = _actor(fromSeed);
        value = bound(value, 0, 100 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    // -------------------------------------------------------- shared raw calls

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok, "transfer returned false");
            assertTrue(to != address(0), "transfer to the zero address succeeded");
            assertLe(amount, fromBefore, "transfer above balance succeeded");
            if (from == to) {
                assertEq(token.balanceOf(from), fromBefore, "self-transfer changed balance");
            } else {
                assertEq(token.balanceOf(from), fromBefore - amount, "sender debited wrong amount");
                assertEq(token.balanceOf(to), toBefore + amount, "recipient credited wrong amount");
            }
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            _touch(to);
            successfulTransfers++;
        } catch (bytes memory err) {
            if (to == address(0)) {
                assertEq(err, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            } else {
                assertGt(amount, fromBefore, "transfer within balance reverted");
                assertEq(
                    err,
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, fromBefore, amount)
                );
            }
            assertEq(token.balanceOf(from), fromBefore, "revert changed sender balance");
            assertEq(token.balanceOf(to), toBefore, "revert changed recipient balance");
            expectedReverts++;
        }
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        uint256 before = token.allowance(owner, spender);
        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            assertTrue(ok, "approve returned false");
            assertTrue(spender != address(0), "approve of the zero spender succeeded");
            assertEq(token.allowance(owner, spender), amount, "allowance not set to the requested amount");
            ghostAllowance[owner][spender] = amount;
            successfulApprovals++;
        } catch (bytes memory err) {
            assertEq(spender, address(0), "approve of a non-zero spender reverted");
            assertEq(err, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            assertEq(token.allowance(owner, spender), before, "revert changed the allowance");
            expectedReverts++;
        }
    }

    function _transferFrom(address spender, address owner, address to, uint256 amount) internal {
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        uint256 allowed = token.allowance(owner, spender);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            assertTrue(ok, "transferFrom returned false");
            assertTrue(to != address(0), "transferFrom to the zero address succeeded");
            assertLe(amount, allowed, "transferFrom above allowance succeeded");
            assertLe(amount, ownerBefore, "transferFrom above balance succeeded");
            if (owner == to) {
                assertEq(token.balanceOf(owner), ownerBefore, "self transferFrom changed balance");
            } else {
                assertEq(token.balanceOf(owner), ownerBefore - amount, "owner debited wrong amount");
                assertEq(token.balanceOf(to), toBefore + amount, "recipient credited wrong amount");
            }
            if (allowed == type(uint256).max) {
                assertEq(token.allowance(owner, spender), allowed, "infinite allowance was decremented");
            } else {
                assertEq(token.allowance(owner, spender), allowed - amount, "allowance not decremented by amount");
                ghostAllowance[owner][spender] = allowed - amount;
            }
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
            _touch(to);
            successfulTransferFroms++;
        } catch (bytes memory err) {
            if (amount > allowed) {
                assertEq(
                    err,
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
                );
            } else if (to == address(0)) {
                assertEq(err, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            } else {
                assertGt(amount, ownerBefore, "transferFrom within balance and allowance reverted");
                assertEq(
                    err,
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, ownerBefore, amount)
                );
            }
            assertEq(token.balanceOf(owner), ownerBefore, "revert changed owner balance");
            assertEq(token.balanceOf(to), toBefore, "revert changed recipient balance");
            assertEq(token.allowance(owner, spender), allowed, "revert changed the allowance");
            expectedReverts++;
        }
    }
}

/// @title Invariants of McLovin.id over random call sequences.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract McLovinIdInvariantTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    McLovinId token;
    McLovinIdHandler handler;
    address deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new McLovinId();

        address[] memory others = new address[](5);
        others[0] = makeAddr("alice");
        others[1] = makeAddr("bob");
        others[2] = makeAddr("carol");
        others[3] = makeAddr("dave");
        others[4] = address(new ContractHolder());

        handler = new McLovinIdHandler(token, deployer, others);

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.transferClamped.selector;
        selectors[1] = handler.transferFull.selector;
        selectors[2] = handler.transferToSelf.selector;
        selectors[3] = handler.approveClamped.selector;
        selectors[4] = handler.approveInfinite.selector;
        selectors[5] = handler.transferFromClamped.selector;
        selectors[6] = handler.approveThenTransferFrom.selector;
        selectors[7] = handler.transferUnclamped.selector;
        selectors[8] = handler.approveUnclamped.selector;
        selectors[9] = handler.transferFromUnclamped.selector;
        selectors[10] = handler.strangerTransferFrom.selector;
        selectors[11] = handler.privilegedCall.selector;
        selectors[12] = handler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // -------------------------------------------------------------- invariants

    /// @dev Fixed supply: nothing in any sequence mints or burns.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// @dev Conservation: every minted unit sits in exactly one of the addresses that ever received
    /// tokens. Read straight from the token, independent of the ledger model.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.touched(i));
        }
        assertEq(sum, token.totalSupply(), "balances of all holders do not sum to the supply");
    }

    /// @dev The token's balances match an independent ledger built only from the calls that the
    /// handler saw succeed.
    function invariant_balancesMatchLedgerModel() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            address who = handler.touched(i);
            assertEq(token.balanceOf(who), handler.ghostBalance(who), "balance diverged from the ledger model");
        }
    }

    /// @dev Allowances between actors match the model: set by approve, reduced by transferFrom,
    /// never reduced when infinite, never changed by anything else.
    function invariant_allowancesMatchModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance diverged from the model"
                );
            }
        }
    }

    /// @dev No holder can end up with more than exists, and the zero address never holds anything.
    function invariant_noHolderExceedsSupplyAndZeroAddressIsEmpty() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.touched(i)), EXPECTED_SUPPLY);
        }
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev Metadata is immutable and the token never accumulates ether.
    function invariant_metadataAndEtherBalanceFixed() public view {
        assertEq(token.name(), "McLovin.id");
        assertEq(token.symbol(), "MCLOVIN");
        assertEq(token.decimals(), 18);
        assertEq(address(token).balance, 0);
    }

    /// @dev Non-vacuity guard: after each run the handler must have exercised both success and
    /// failure paths. `afterInvariant` runs once per sequence, after `depth` calls.
    function afterInvariant() public view {
        assertGt(handler.successfulTransfers(), 0, "no transfer succeeded in the run");
        assertGt(handler.expectedReverts() + handler.rejectedPrivilegedCalls(), 0, "no failure path hit in the run");
    }

    // ------------------------------------------------- harness grounding tests

    /// @dev Grounds the handler itself: a scripted sequence through every handler produces the
    /// state the model predicts. A broken harness would make the invariants vacuous.
    function test_handlerScriptedSequenceMatchesModel() public {
        address alice = handler.actors(1);
        address bob = handler.actors(2);

        handler.transferClamped(0, 1, 1_000e18);
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(handler.ghostBalance(alice), 1_000e18);

        handler.transferUnclamped(1, address(0), 1);
        handler.transferUnclamped(1, bob, 1_000e18 + 1);
        assertEq(handler.expectedReverts(), 2);
        assertEq(token.balanceOf(alice), 1_000e18);

        handler.approveClamped(1, 2, 400e18);
        handler.transferFromClamped(2, 1, 2, 250e18);
        assertEq(token.balanceOf(bob), 250e18);
        assertEq(token.allowance(alice, bob), 150e18);
        assertEq(handler.ghostAllowance(alice, bob), 150e18);

        handler.transferFromUnclamped(2, 1, bob, 151e18);
        assertEq(handler.expectedReverts(), 3);

        handler.approveUnclamped(1, address(0), 1);
        assertEq(handler.expectedReverts(), 4);

        handler.strangerTransferFrom(address(0xBAD), 0, 1);
        assertEq(handler.expectedReverts(), 5);

        handler.approveInfinite(1, 2);
        handler.transferFromClamped(2, 1, 2, 100e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);

        handler.transferToSelf(2, 50e18);
        handler.transferFull(2, 1);
        assertEq(token.balanceOf(bob), 0);

        handler.privilegedCall(0, 0, 1);
        handler.sendEther(0, 1 ether);
        assertEq(handler.rejectedPrivilegedCalls(), 1);

        assertEq(handler.successfulTransfers(), 3);
        assertEq(handler.successfulTransferFroms(), 2);
        assertEq(handler.successfulApprovals(), 2);
        invariant_balancesSumToSupply();
        invariant_balancesMatchLedgerModel();
        invariant_allowancesMatchModel();
        invariant_totalSupplyNeverChanges();
    }

    /// @dev Every privileged signature the handler tries is rejected from every actor.
    function test_handlerPrivilegedCallsAllRejected() public {
        for (uint256 which; which < 14; ++which) {
            for (uint256 caller; caller < handler.actorCount(); ++caller) {
                handler.privilegedCall(caller, which, 7);
            }
        }
        assertEq(handler.rejectedPrivilegedCalls(), 14 * handler.actorCount());
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }
}

/// @dev A holder that is a contract with no token-receiving hooks, to show plain transfers reach
/// contract accounts as well as EOAs.
contract ContractHolder {}
