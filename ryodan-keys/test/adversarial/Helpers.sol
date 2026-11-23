// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {RyodanKeys} from "../../src/RyodanKeys.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

abstract contract Fixture is Test {
    RyodanKeys internal keys;
    address internal admin;
    address internal treasury = makeAddr("treasury");
    string internal constant SBT = "ipfs://sbt/";
    string internal constant NFT = "ipfs://nft/";
    uint256 internal end;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        end = block.timestamp + 30 days;
        admin = address(this);
        keys = new RyodanKeys(end, SBT, NFT, admin, treasury);
    }

    function _leaf(address a, uint8 t) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, t))));
    }

    function _hp(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _tree(bytes32[4] memory l) internal pure returns (bytes32 root, bytes32[2][4] memory p) {
        bytes32 n0 = _hp(l[0], l[1]);
        bytes32 n1 = _hp(l[2], l[3]);
        root = _hp(n0, n1);
        p[0] = [l[1], n1];
        p[1] = [l[0], n1];
        p[2] = [l[3], n0];
        p[3] = [l[2], n0];
    }

    function _arr2(bytes32[2] memory p) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](2);
        out[0] = p[0];
        out[1] = p[1];
    }

    function _single(bytes32 x) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](1);
        out[0] = x;
    }

    function _openCivilian(uint256 limit, uint256 price) internal {
        keys.configureAllowlist(bytes32(0), keccak256("empty"), 0, 0, 0);
        keys.configurePhase(4, price, limit);
        while (keys.currentPhase() < 4) keys.advancePhase();
        keys.setMintPaused(false);
    }

    function _buy(address who, uint256 amount) internal {
        uint8 ph = keys.currentPhase();
        uint256 price = keys.mintPrice();
        uint256 value = amount * price;
        vm.deal(who, who.balance + value);
        vm.prank(who);
        keys.mint{value: value}(amount, ph, price);
    }

    function _sellOut(address collector) internal {
        _openCivilian(6166, 0.01 ether);
        _buy(collector, 6166);
        vm.prank(treasury);
        keys.treasuryMint(500, treasury);
    }

    function _toEnd() internal {
        vm.warp(end + 1);
    }

    function _solvent() internal view returns (bool) {
        uint256 owed = keys.totalPendingRefund() + keys.keptFunds() - keys.keptWithdrawn();
        return address(keys).balance >= owed;
    }

    receive() external payable {}
}

contract RejectETH is IERC721Receiver {
    RyodanKeys public immutable k;

    constructor(RyodanKeys k_) {
        k = k_;
    }

    function buy(uint256 a) external payable {
        uint8 p = k.currentPhase();
        uint256 pr = k.mintPrice();
        k.mint{value: msg.value}(a, p, pr);
    }

    function keep(uint256[] calldata ids, uint256[] calldata none) external {
        k.settle(ids, none);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        revert("no eth");
    }
}

contract Recorder {
    RyodanKeys public immutable k;
    uint256 public hits;

    constructor(RyodanKeys k_) {
        k = k_;
    }

    function buy(uint256 a) external payable {
        uint8 p = k.currentPhase();
        uint256 pr = k.mintPrice();
        k.mint{value: msg.value}(a, p, pr);
    }

    receive() external payable {
        hits++;
    }
}

contract HeavyWallet is IERC721Receiver {
    RyodanKeys public immutable k;
    uint256 public slot;
    uint256 public s2;
    uint256 public s3;

    constructor(RyodanKeys k_) {
        k = k_;
    }

    function buy(uint256 a) external payable {
        uint8 p = k.currentPhase();
        uint256 pr = k.mintPrice();
        k.mint{value: msg.value}(a, p, pr);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        slot = slot + 1;
        s2 = s2 + 1;
        s3 = s3 + 1;
    }
}

contract ReenterNFT {
    RyodanKeys public immutable k;
    bytes public lastError;
    bool public entered;
    uint256 public burnOk;
    uint256 public mode;

    constructor(RyodanKeys k_) {
        k = k_;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function buy(uint256 a) external payable {
        uint8 p = k.currentPhase();
        uint256 pr = k.mintPrice();
        k.mint{value: msg.value}(a, p, pr);
    }

    function keep(uint256[] calldata ids, uint256[] calldata none) external {
        k.settle(ids, none);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (mode == 1) {
            uint256[] memory ids = new uint256[](1);
            ids[0] = id;
            try k.refundBatch(ids) {
                entered = true;
            } catch (bytes memory e) {
                lastError = e;
            }
        }
        if (mode == 2) {
            try k.claimPendingRefund(payable(address(this))) {
                entered = true;
            } catch (bytes memory e) {
                lastError = e;
            }
        }
        if (mode == 3) {
            try k.withdraw() {
                entered = true;
            } catch (bytes memory e) {
                lastError = e;
            }
        }
        if (mode == 4) {
            try k.burn(id) {
                burnOk++;
            } catch (bytes memory e) {
                lastError = e;
            }
        }
        if (mode == 5) {
            try k.mint{value: 2 * k.mintPrice()}(2, k.currentPhase(), k.mintPrice()) {
                entered = true;
            } catch (bytes memory e) {
                lastError = e;
            }
        }
        if (mode == 6) {
            try k.treasuryMint(1, address(this)) {
                entered = true;
            } catch (bytes memory e) {
                lastError = e;
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }
    receive() external payable {}
}

contract ReenterETH is IERC721Receiver {
    RyodanKeys public immutable k;
    uint256 public mode;
    bool public entered;
    bytes public lastError;

    constructor(RyodanKeys k_) {
        k = k_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function buy(uint256 a) external payable {
        uint8 p = k.currentPhase();
        uint256 pr = k.mintPrice();
        k.mint{value: msg.value}(a, p, pr);
    }

    function keep(uint256[] calldata ids, uint256[] calldata none) external {
        k.settle(ids, none);
    }

    function claim(uint256 id) external {
        k.refund(id);
    }

    receive() external payable {
        if (mode == 1) {
            uint256[] memory ids = new uint256[](1);
            ids[0] = 999;
            try k.refundBatch(ids) {
                entered = true;
            } catch {}
        }
        if (mode == 2) {
            try k.claimPendingRefund(payable(address(this))) {
                entered = true;
            } catch {}
        }
        if (mode == 3) {
            try k.settle(new uint256[](0), new uint256[](0)) {
                entered = true;
            } catch {}
        }
        if (mode == 4) {
            try k.refund(2) {
                entered = true;
            } catch (bytes memory e) {
                lastError = e;
            }
        }
        if (mode == 5) {
            try k.refund(1) {
                entered = true;
            } catch (bytes memory e) {
                lastError = e;
            }
        }
    }
}
