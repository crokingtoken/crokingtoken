// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "witnet-solidity-bridge/contracts/UsingWitnet.sol";
import "witnet-solidity-bridge/contracts/requests/WitnetRequest.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract WheelSpinGame is Ownable, UsingWitnet {
    uint256 public constant SPIN_COST = 10 ether; // 10 CRO
    uint256 public constant JACKPOT_CHANCE = 100; // 1 in 100 chance of hitting the jackpot

    IWitnetRequest public witnetRequest;
    bytes32 public witnetRandomness;
    uint256 public witnetQueryId;

    struct Prize {
        address tokenAddress;
        uint256 tokenId;
        bool isERC721;
    }

    Prize[] public prizes;
    Prize public jackpotPrize;

    event SpinResult(address indexed user, uint256 indexed prizeIndex, Prize prize);
    event JackpotWon(address indexed user, Prize jackpotPrize);

    constructor(WitnetRequestBoard _witnet) UsingWitnet(_witnet) {
        witnetRequest = new WitnetRequest(
            hex"0a0f120508021a01801a0210022202100b10e807180a200a2833308094ebdc03"
        );
    }

    function addERC20Prize(address tokenAddress, uint256 amount) external onlyOwner {
        prizes.push(Prize(tokenAddress, amount, false));
    }

    function addERC721Prize(address tokenAddress, uint256 tokenId) external onlyOwner {
        prizes.push(Prize(tokenAddress, tokenId, true));
        IERC721(tokenAddress).transferFrom(msg.sender, address(this), tokenId);
    }

    function setJackpotPrize(address tokenAddress, uint256 tokenId, bool isERC721) external onlyOwner {
        if (jackpotPrize.isERC721 && jackpotPrize.tokenId != 0) {
            IERC721(jackpotPrize.tokenAddress).transferFrom(address(this), msg.sender, jackpotPrize.tokenId);
        }
        jackpotPrize = Prize(tokenAddress, tokenId, isERC721);
        if (isERC721) {
            IERC721(tokenAddress).transferFrom(msg.sender, address(this), tokenId);
        }
    }

    function spin() external payable {
        require(msg.value == SPIN_COST, "Incorrect spin cost");

        _fetchRandomNumber();
        uint256 prizeIndex = uint256(witnetRandomness) % (prizes.length * JACKPOT_CHANCE);
        bool isJackpot = prizeIndex >= prizes.length;

        if (isJackpot) {
            if (jackpotPrize.isERC721) {
                IERC721(jackpotPrize.tokenAddress).transferFrom(address(this), msg.sender, jackpotPrize.tokenId);
            } else {
                IERC20(jackpotPrize.tokenAddress).transfer(msg.sender, jackpotPrize.tokenId);
            }
            emit JackpotWon(msg.sender, jackpotPrize);
        } else {
            Prize memory prize = prizes[prizeIndex];
            if (prize.isERC721) {
                IERC721(prize.tokenAddress).transferFrom(address(this), msg.sender, prize.tokenId);
            } else {
                IERC20(prize.tokenAddress).transfer(msg.sender, prize.tokenId);
            }
            emit SpinResult(msg.sender, prizeIndex, prize);
        }
    }

    function _fetchRandomNumber() internal {
        uint256 _witnetReward;
        (witnetQueryId, _witnetReward) = _witnetPostRequest(witnetRequest);

        require(_witnetCheckResultAvailability(witnetQueryId), "Randomness not yet reported");

        Witnet.Result memory _result = witnet.readResponseResult(witnetQueryId);
        require(_result.success, "Randomness request failed");

        witnetRandomness = witnet.asBytes32(_result);
    }

    function withdrawERC20(address tokenAddress, uint256 amount) external onlyOwner {
        IERC20(tokenAddress).transfer(msg.sender, amount);
    }

    function withdrawERC721(address tokenAddress, uint256 tokenId) external onlyOwner {
        IERC721(tokenAddress).transferFrom(address(this), msg.sender, tokenId);
    }

    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        payable(msg.sender).transfer(balance);
    }
}


