// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";

import {GPv2Order} from "@cow-protocol/contracts/libraries/GPv2Order.sol";
import {IERC20} from "@cow-protocol/contracts/interfaces/IERC20.sol";

import {IGPv2Settlement} from "../interfaces/IGPv2Settlement.sol";
import {IPriceChecker} from "../interfaces/IPriceChecker.sol";

/// @title Milkman
/// @notice Trustlessly execute swaps through the CoW Protocol.
/// @dev Design documentation on HackMD: https://hackmd.io/XIOWY5VPRuqBO_74Aef61w?view. Use with atypical tokens (e.g., rebasing tokens) not recommended.
contract Milkman {
    using SafeERC20 for IERC20;
    using GPv2Order for GPv2Order.Data;
    using GPv2Order for bytes;
    using SafeMath for uint256;

    event SwapRequested(
        bytes32 swapID,
        address user,
        address receiver,
        IERC20 fromToken,
        IERC20 toToken,
        uint256 amountIn,
        address priceChecker,
        bytes priceCheckerData,
        uint256 nonce
    );
    // swapID is generated by Milkman, orderUID is generated by CoW Protocol
    event SwapPaired(bytes32 swapID, bytes orderUID, uint256 blockNumber);
    event SwapUnpaired(bytes32 swapID);
    event SwapExecuted(bytes32 swapID);
    event SwapCancelled(bytes32 swapID);

    bytes32 internal swapHash;

    bool internal isOriginal = true;
    bool internal isInitialized; // clones set this to true

    // Who we give allowance
    address internal constant gnosisVaultRelayer =
        0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    // Where we pre-sign
    IGPv2Settlement internal constant settlement =
        IGPv2Settlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);
    // Settlement's domain separator, used to hash order IDs
    bytes32 internal constant domainSeparator =
        0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;

    bytes32 internal constant KIND_SELL =
        hex"f3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775";

    bytes32 internal constant BALANCE_ERC20 =
        hex"5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9";

    // The byte length of an order unique identifier.
    uint256 internal constant UID_LENGTH = 56;

    /// @notice Swap an exact amount of tokens for a market-determined amount of other tokens.
    /// @dev Stores a hash of this swap in storage, putting it in requested state.
    /// @param _amountIn The number of tokens to sell.
    /// @param _fromToken The token that the user wishes to sell.
    /// @param _toToken The token that the user wishes to buy.
    /// @param _to Who should receive the bought tokens.
    /// @param _priceChecker An optional contract (use address(0) for none) that checks, on behalf of the user, that the CoW protocol order that Milkman signs has set a reasonable minOut.
    /// @param _priceCheckerData Optional data that gets passed to the price checker.
    function requestSwapExactTokensForTokens(
        uint256 _amountIn,
        IERC20 _fromToken,
        IERC20 _toToken,
        address _to,
        address _priceChecker,
        bytes calldata _priceCheckerData
    ) external {
        require(isOriginal); // dev: can't request swap from order contract

        address _orderContract = createOrderContract();

        // transfer from needs to happen before initialize to prevent re-entrancy

        _fromToken.transferFrom(msg.sender, _orderContract, _amountIn); // TODO: figure out how to make this a safeTransfer

        bytes32 _swapHash = keccak256(
            abi.encode(
                _to,
                _fromToken,
                _toToken,
                _amountIn,
                _priceChecker,
                _priceCheckerData
            )
        );

        Milkman(_orderContract).initialize(_fromToken, _swapHash);

        // emit SwapRequested(
        //     msg.sender,
        //     _to,
        //     _fromToken,
        //     _toToken,
        //     _amountIn,
        //     _priceChecker,
        //     _priceCheckerData,
        //     _orderContract
        // );
    }

    function initialize(IERC20 _fromToken, bytes32 _swapHash) external {
        require(!isOriginal); // dev: should only be called on order contracts
        require(!isInitialized); // dev: cannot re-initialize an order contract

        isInitialized = true;

        _fromToken.approve(gnosisVaultRelayer, type(uint256).max);

        swapHash = _swapHash;
    }

    /// @param _encodedOrder [all fields in GPv2Order.Data, priceChecker, priceCheckerData]
    function isValidSignature(
        bytes32 _orderDigest, // _orderDigest is TRUSTED
        bytes calldata _encodedOrder // _encodedOrder is UNTRUSTED
    ) external view returns (bytes4) {
        // require(msg.sender == address(settlement)); // dev: the settlement contract must call

        (
            GPv2Order.Data memory _order,
            address _priceChecker,
            bytes memory _priceCheckerData
        ) = decodeOrder(_encodedOrder);

        require(_order.hash(domainSeparator) == _orderDigest, "!match");

        require(_order.kind == KIND_SELL, "!kind_sell");

        require(
            _order.validTo >= block.timestamp + 5 minutes,
            "expires_too_soon"
        ); // we might not need this anymore, since the griefing attack doesn't really make sense when multiple orders can be active at the same time

        require(!_order.partiallyFillable, "!fill_or_kill");

        require(_order.sellTokenBalance == BALANCE_ERC20, "!sell_erc20");

        require(_order.buyTokenBalance == BALANCE_ERC20, "!buy_erc20");

        if (_priceChecker != address(0)) {
            require(
                IPriceChecker(_priceChecker).checkPrice(
                    _order.sellAmount.add(_order.feeAmount),
                    address(_order.sellToken),
                    address(_order.buyToken),
                    _order.buyAmount,
                    _priceCheckerData
                ),
                "invalid_min_out"
            );
        }

        bytes32 _swapHash = keccak256(
            abi.encode(
                _order.receiver,
                _order.sellToken,
                _order.buyToken,
                _order.sellAmount.add(_order.feeAmount),
                _priceChecker,
                _priceCheckerData
            )
        );

        if (_swapHash == swapHash) {
            // should be true as long as the keeper isn't submitting bad orders
            return 0x1626ba7e; // magic number
        } else {
            return 0xffffffff;
        }
    }

    function decodeOrder(bytes memory _encodedOrder)
        internal
        pure
        returns (
            GPv2Order.Data memory,
            address,
            bytes memory
        )
    {
        (
            address _sellToken,
            address _buyToken,
            address _receiver,
            uint256 _sellAmount,
            uint256 _buyAmount,
            uint32 _validTo,
            bytes32 _appData,
            uint256 _feeAmount,
            bytes32 _kind,
            bool _partiallyFillable,
            bytes32 _sellTokenBalance,
            bytes32 _buyTokenBalance,
            address _priceChecker,
            bytes memory _priceCheckerData
        ) = abi.decode(
                _encodedOrder,
                (
                    address,
                    address,
                    address,
                    uint256,
                    uint256,
                    uint32,
                    bytes32,
                    uint256,
                    bytes32,
                    bool,
                    bytes32,
                    bytes32,
                    address,
                    bytes
                )
            );

        return (
            GPv2Order.Data(
                IERC20(_sellToken),
                IERC20(_buyToken),
                _receiver,
                _sellAmount,
                _buyAmount,
                _validTo,
                _appData,
                _feeAmount,
                _kind,
                _partiallyFillable,
                _sellTokenBalance,
                _buyTokenBalance
            ),
            _priceChecker,
            _priceCheckerData
        );
    }

    function createOrderContract() internal returns (address _orderContract) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol

        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            _orderContract := create(0, clone_code, 0x37)
        }
    }
}
