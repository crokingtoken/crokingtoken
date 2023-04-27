// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "witnet-solidity-bridge/contracts/UsingWitnet.sol";
import "witnet-solidity-bridge/contracts/requests/WitnetRequest.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CoinFlipGame is UsingWitnet, Ownable {
    using SafeMath for uint256;

    uint256 constant FEE_PERCENTAGE = 5;
    IWitnetRequest public witnetRequest;
    bytes32 public witnetRandomness;
    uint256 public witnetQueryId;

    enum Status {
        Playing,
        Randomizing,
        Awarding
    }

    struct Player {
        address payable playerAddress;
        uint256 betAmount;
        IERC20 token;
    }

    Player public player;
    Status public currentStatus = Status.Playing;

    mapping(address => bool) public whitelistedTokens;

    event BetPlaced(address indexed player, uint256 amount, address indexed tokenAddress);
    event GameResult(address indexed winner, uint256 winningAmount, address indexed tokenAddress);
    event TokenWhitelisted(address indexed tokenAddress);

    modifier inStatus(Status _status) {
        require(currentStatus == _status, "Invalid status");
        _;
    }

    constructor(WitnetRequestBoard _witnet)
        UsingWitnet(_witnet)
    {
        witnetRequest = new WitnetRequest(
            hex"0a0f120508021a01801a0210022202100b10e807180a200a2833308094ebdc03"
        );
    }

    function whitelistToken(address tokenAddress) external onlyOwner {
        whitelistedTokens[tokenAddress] = true;
        emit TokenWhitelisted(tokenAddress);
    }

    function unwhitelistToken(address tokenAddress) external onlyOwner {
        whitelistedTokens[tokenAddress] = false;
    }

    function placeBet(address tokenAddress, uint256 amount) external payable inStatus(Status.Playing) {
        require(amount > 0, "Invalid bet amount");
        require(player.playerAddress == address(0), "A bet is already placed");

        IERC20 token;
        if (tokenAddress != address(0)) {
            require(whitelistedTokens[tokenAddress], "Token not whitelisted");
            token = IERC20(tokenAddress);
            require(token.allowance(msg.sender, address(this)) >= amount, "Allowance insufficient");
            token.transferFrom(msg.sender, address(this), amount);
        } else {
            require(msg.value == amount, "Invalid ether amount");
        }

        player = Player(payable(msg.sender), amount, token);
        emit BetPlaced(msg.sender, amount, tokenAddress);

        // Start randomizing
        uint256 _witnetReward;
        (witnetQueryId, _witnetReward) = _witnetPostRequest(witnetRequest);
        currentStatus = Status.Randomizing;
    }

    function getResult() external inStatus(Status.Randomizing) {
        uint _queryId = witnetQueryId;

        require(_witnetCheckResultAvailability(_queryId), "Result not available");

        Witnet.Result memory _result = witnet.readResponseResult(_queryId);
        if (_result.success) {
            witnetRandomness = witnet.asBytes32(_result);
            currentStatus = Status.Awarding;
            awardWinner();
        } else {
            // step back to 'Playing' status
            witnetQueryId = 0;
            currentStatus = Status.Playing;
        }
    }

    function awardWinner() private inStatus(Status.Awarding) {
        require(player.playerAddress != address(0), "No bet placed");

        bool isHeads = uint256(witnetRandomness) % 2 == 0;
        bool isWinner = (block.timestamp % 2 == 0) == isHeads;

        uint256 winningAmount = player.betAmount.mul(100 - FEE_PERCENTAGE).div(100);

        if (isWinner) {
            if (address(player.token) == address(0)) {
                player.playerAddress.transfer(winningAmount);
            } else {
                player.token.transfer(player.playerAddress, winningAmount);
            }
            emit GameResult(player.playerAddress, winningAmount, address(player.token));
        } else {
            emit GameResult(owner(), player.betAmount, address(player.token));
        }


        // Reset game state
        player.playerAddress = payable(address(0));
        player.betAmount = 0;
        player.token = IERC20(address(0));
        witnetRandomness = bytes32(0);
        witnetQueryId = 0;
        currentStatus = Status.Playing;
    }    

    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;

        if (balance > 0) {
            payable(owner()).transfer(balance);
        }
    }

    function withdrawTokenFees(address tokenAddress) external onlyOwner {
        require(whitelistedTokens[tokenAddress], "Token not whitelisted");
        IERC20 token = IERC20(tokenAddress);
        uint256 tokenBalance = token.balanceOf(address(this));
        if (tokenBalance > 0) {
        token.transfer(owner(), tokenBalance);
        }
    }        

    function getStatus() external view returns (Status) {
        return currentStatus;
    }

    function getGameDetails() external view returns (Player memory, Status) {
        return (player, currentStatus);
    }
}
