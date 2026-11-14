// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MUSDGoals} from "../contracts/MUSDGoals.sol";
import {DemoMUSD} from "../contracts/DemoMUSD.sol";

/// @dev Minimal cheatcode interface — keeps the script dependency-free
///      (no forge-std download needed, builds fully offline).
interface Vm {
    function envUint(string calldata name) external returns (uint256);
    function envAddress(string calldata name) external returns (address);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

/// @title Deploy — deploys DemoMUSD + both MUSDGoals instances to Mezo Testnet
/// @notice Expects env vars:
///           PRIVATE_KEY   deployer private key (set by deploy.sh, never logged)
///           REAL_MUSD     official testnet MUSD address
///         Run via deploy.sh, which handles the balance gate, address
///         extraction from the broadcast artefact, demo seeding, and the
///         DEPLOYED.txt / frontend config generation.
contract Deploy {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant DEFAULT_REAL_MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;

    function run() external returns (address demoMusd, address goalsReal, address goalsDemo) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address realMusd = DEFAULT_REAL_MUSD;
        // REAL_MUSD env override is optional; deploy.sh always passes the
        // official address explicitly. If your forge build supports try/catch
        // on env reads you can wire it here — deploy.sh pins the default.

        vm.startBroadcast(deployerKey);

        DemoMUSD demo = new DemoMUSD();
        demoMusd = address(demo);

        MUSDGoals real = new MUSDGoals(realMusd);
        goalsReal = address(real);

        MUSDGoals demoGoals = new MUSDGoals(demoMusd);
        goalsDemo = address(demoGoals);

        vm.stopBroadcast();
    }
}
