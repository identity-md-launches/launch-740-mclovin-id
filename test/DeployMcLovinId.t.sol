// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployMcLovinId} from "../script/DeployMcLovinId.s.sol";
import {McLovinId} from "../src/McLovinId.sol";

contract DeployMcLovinIdTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    function test_deployMintsWholeSupplyToTheScriptCaller() public {
        DeployMcLovinId deployer = new DeployMcLovinId();
        McLovinId token = deployer.deploy();
        // The script contract is msg.sender of the creation, so it holds the supply.
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(deployer)), EXPECTED_SUPPLY);
        assertEq(token.name(), "McLovin.id");
        assertEq(token.symbol(), "MCLOVIN");
        assertEq(token.decimals(), 18);
    }

    function test_deployTwiceGivesIndependentTokens() public {
        DeployMcLovinId deployer = new DeployMcLovinId();
        McLovinId first = deployer.deploy();
        McLovinId second = deployer.deploy();
        assertTrue(address(first) != address(second));
        assertEq(first.totalSupply(), EXPECTED_SUPPLY);
        assertEq(second.totalSupply(), EXPECTED_SUPPLY);
        assertEq(first.balanceOf(address(deployer)), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(address(deployer)), EXPECTED_SUPPLY);
    }
}
