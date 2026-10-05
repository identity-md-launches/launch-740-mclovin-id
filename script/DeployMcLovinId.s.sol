// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {McLovinId} from "../src/McLovinId.sol";

/// @title Deploy script for McLovin.id
/// @notice The token has no configuration: its name, symbol, decimals and supply are fixed in the
/// contract, and the whole supply goes to whichever account sends the creation transaction.
/// @dev `deploy()` is the unit the tests exercise. `run()` only wraps it in a broadcast; it reads
/// nothing from the environment. In the IdentityMD launch the token is not deployed by this script
/// at all but by ProjectFactory.launchCustom, which passes the same (empty) constructor arguments.
contract DeployMcLovinId is Script {
    /// @notice Deploys the token. The caller of the creation receives the full supply.
    function deploy() public returns (McLovinId token) {
        token = new McLovinId();
    }

    /// @notice Broadcasts the deployment with the signer the invoker configured on the command line.
    function run() external returns (McLovinId token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
