// SPDX-License-Identifier: BUSL-1.1

/*
 * Substance Exchange Contracts
 * @author Substance Technologies Limited
 * Based on Votium MultiMerkleStash
 * https://etherscan.io/address/0x378ba9b73309be80bf4c2c027aad799766a7ed5a#code
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract MultiMerkleStash is Ownable {
    using SafeERC20 for IERC20;

    struct ClaimParam {
        address token;
        uint256 update;
        uint256 index;
        uint256 amount;
        bytes32[] merkleProof;
    }

    // environment variables for updatable merkle
    mapping(address => mapping(uint256 => bytes32)) public merkleRoot;
    mapping(address => uint256) public updateOffset;
    // This is a packed array of booleans.
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) private claimedBitMap;

    function isClaimed(address token, uint256 index, uint256 _update) public view returns (bool) {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        uint256 claimedWord = claimedBitMap[token][_update][claimedWordIndex];
        uint256 mask = (1 << claimedBitIndex);
        return claimedWord & mask == mask;
    }

    function _setClaimed(address token, uint256 index, uint256 update) private {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        claimedBitMap[token][update][claimedWordIndex] = claimedBitMap[token][update][claimedWordIndex] | (1 << claimedBitIndex);
    }

    function claim(address token, uint256 update, uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) public {
        require(merkleRoot[token][update] != 0, "frozen");
        require(!isClaimed(token, index, update), "Drop already claimed.");

        // Verify the merkle proof.
        require(MerkleProof.verifyCalldata(merkleProof, merkleRoot[token][update], keccak256(abi.encodePacked(index, account, amount))), "Invalid proof.");

        _setClaimed(token, index, update);
        IERC20(token).safeTransfer(account, amount);

        emit Claimed(token, index, amount, account, update);
    }

    function claimMulti(address account, ClaimParam[] calldata claims) external {
        unchecked {
            for (uint256 i; i < claims.length; ++i) {
                claim(claims[i].token, claims[i].update, claims[i].index, account, claims[i].amount, claims[i].merkleProof);
            }
        }
    }

    function updateMerkleRoot(address token, bytes32 _merkleRoot) external onlyOwner {
        // Increment the update (simulates the clearing of the claimedBitMap)
        updateOffset[token] += 1;
        uint256 offset = updateOffset[token];
        // Set the new merkle root
        merkleRoot[token][offset] = _merkleRoot;

        emit MerkleRootUpdated(token, _merkleRoot, offset);
    }

    function recoverToken(address[] calldata tokens) external onlyOwner {
        unchecked {
            for (uint256 i; i < tokens.length; ++i) {
                IERC20(tokens[i]).safeTransfer(msg.sender, IERC20(tokens[i]).balanceOf(address(this)));
            }
        }
    }

    // EVENTS //

    event Claimed(address indexed token, uint256 index, uint256 amount, address indexed account, uint256 indexed update);
    event MerkleRootUpdated(address indexed token, bytes32 indexed merkleRoot, uint256 indexed update);
}
