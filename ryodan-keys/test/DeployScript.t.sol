// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {RyodanKeys} from "../src/RyodanKeys.sol";
import {RyodanKeysScript} from "../script/RyodanKeys.s.sol";

contract DeployScriptTest is Test {
    address internal deployer = makeAddr("deployer");
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    uint256 internal end;
    RyodanKeysScript internal script;

    function setUp() public {
        vm.warp(1_800_000_000);
        end = block.timestamp + 30 days;
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));
        vm.setEnv("ADMIN_ADDRESS", vm.toString(admin));
        vm.setEnv("TREASURY_ADDRESS", vm.toString(treasury));
        vm.setEnv("MINT_END_TIME", vm.toString(end));
        vm.setEnv("HIDDEN_METADATA_URI", "ipfs://hidden/hidden.json");
        script = new RyodanKeysScript();
    }

    function test_DeploymentScriptAssignsExplicitRolesOnSepolia() public {
        vm.chainId(11155111);
        RyodanKeys keys = script.run();
        assertTrue(keys.hasRole(keys.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(keys.hasRole(keys.TREASURY_ROLE(), treasury));
        assertFalse(keys.hasRole(keys.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(keys.hasRole(keys.TREASURY_ROLE(), deployer));
        assertFalse(keys.hasRole(keys.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(keys.hasRole(keys.DEFAULT_ADMIN_ROLE(), address(script)));
        assertEq(keys.mintEndTime(), end);
        assertEq(keys.hiddenMetadataURI(), "ipfs://hidden/hidden.json");
    }

    function test_DeploymentScriptAllowsLocalAnvil() public {
        vm.chainId(31337);
        RyodanKeys keys = script.run();
        assertGt(address(keys).code.length, 0);
        assertEq(keys.currentPhase(), 0);
    }

    function test_DeploymentScriptRejectsMainnet() public {
        vm.chainId(1);
        vm.expectRevert("Use Ethereum Sepolia or local Anvil");
        script.run();
    }

    function test_DeploymentScriptRejectsExpiredConfiguration() public {
        vm.chainId(11155111);
        vm.warp(end);
        vm.expectRevert("Deadline must be in the future");
        script.run();
    }
}
