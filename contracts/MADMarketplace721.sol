// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.4;

/* 
DISCLAIMER: 
This contract hasn't been audited yet. Most likely contains unexpected bugs. 
Don't trust your funds to be held by this code before the final thoroughly tested and audited version release.
*/

/// @author Modified from NFTEX
/// (https://github.com/TheGreatHB/NFTEX/blob/main/contracts/NFTEX.sol)

import { MAD } from "./MAD.sol";
import { MarketplaceEventsAndErrors721, FactoryVerifier, IERC721 } from "./EventsAndErrors.sol";
import { Types } from "./Types.sol";
import { Pausable } from "./lib/security/Pausable.sol";
import { Owned } from "./lib/auth/Owned.sol";
import { ERC721Holder } from "./lib/tokens/ERC721/Base/utils/ERC721Holder.sol";
import { SafeTransferLib } from "./lib/utils/SafeTransferLib.sol";

contract MADMarketplace721 is
    MAD,
    MarketplaceEventsAndErrors721,
    ERC721Holder,
    Owned(msg.sender),
    Pausable
{
    using Types for Types.Order721;

    /// @dev Function Signature := 0x06fdde03
    function name()
        public
        pure
        override(MAD)
        returns (string memory)
    {
        assembly {
            mstore(0x20, 0x20)
            mstore(0x46, 0x066D61726B6574)
            return(0x20, 0x60)
        }
    }

    ////////////////////////////////////////////////////////////////
    //                           STORAGE                          //
    ////////////////////////////////////////////////////////////////

    // uint256 constant NAME_SLOT =
    // 0x8b30951df380b6b10da747e1167dd8e40bf8604c88c75b245dc172767f3b7320;

    uint16 public constant feePercent1 = 2.5e2;
    uint16 public constant feePercent0 = 1.0e3;
    uint16 public constant basisPoints = 1.0e4;

    /// @dev token => id => orderID[]
    mapping(IERC721 => mapping(uint256 => bytes32[]))
        public orderIdByToken;

    /// @dev seller => orderID
    mapping(address => bytes32[]) public orderIdBySeller;

    /// @dev orderID => order details
    mapping(bytes32 => Types.Order721) public orderInfo;

    /// @dev token => tokenId => case0(feePercent0)/case1(feePercent1)
    mapping(uint256 => mapping(uint256 => bool))
        public feeSelector;

    uint256 public minOrderDuration;
    uint256 public minAuctionIncrement;
    uint256 public minBidValue;

    address public recipient;
    FactoryVerifier public MADFactory721;

    ////////////////////////////////////////////////////////////////
    //                         CONSTRUCTOR                        //
    ////////////////////////////////////////////////////////////////

    constructor(
        address _recipient,
        uint256 _minOrderDuration,
        FactoryVerifier _factory
    ) {
        setFactory(_factory);
        setRecipient(_recipient);
        updateSettings(
            300, // 5 min
            _minOrderDuration,
            20 // 5% (1/20th)
        );
    }

    ////////////////////////////////////////////////////////////////
    //                           USER FX                          //
    ////////////////////////////////////////////////////////////////

    /// @notice Fixed Price listing order public pusher.
    /// @dev Function Signature := 0x40b78b0f
    function fixedPrice(
        IERC721 _token,
        uint256 _id,
        uint256 _price,
        uint256 _endTime
    ) public whenNotPaused {
        _makeOrder(0, _token, _id, _price, 0, _endTime);
    }

    /// @notice Dutch Auction listing order public pusher.
    /// @dev Function Signature := 0x205e409c
    function dutchAuction(
        IERC721 _token,
        uint256 _id,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _endTime
    ) public whenNotPaused {
        _exceedsMaxEP(_startPrice, _endPrice);
        _makeOrder(
            1,
            _token,
            _id,
            _startPrice,
            _endPrice,
            _endTime
        );
    }

    /// @notice English Auction listing order public pusher.
    /// @dev Function Signature := 0x47c4be17
    function englishAuction(
        IERC721 _token,
        uint256 _id,
        uint256 _startPrice,
        uint256 _endTime
    ) public whenNotPaused {
        _makeOrder(2, _token, _id, _startPrice, 0, _endTime);
    }

    /// @notice Bidding function available for English Auction only.
    /// @dev Function Signature := 0x957bb1e0
    /// @dev By default, bids must be at least 5% higher than the previous one.
    /// @dev By default, auction will be extended in 5 minutes if last bid is placed 5 minutes prior to auction's end.
    /// @dev 5 minutes eq to 300 mined blocks since block mining time is expected to take 1s in the harmony blockchain.
    function bid(bytes32 _order)
        external
        payable
        whenNotPaused
    {
        Types.Order721 storage order = orderInfo[_order];

        uint256 lastBidPrice = order.lastBidPrice;

        _bidChecks(
            order.orderType,
            order.endTime,
            order.seller,
            lastBidPrice,
            order.startPrice
        );

        // 1s blocktime
        assembly {
            let endTime := and(
                sload(add(order.slot, 4)),
                shr(32, not(0))
            )
            if gt(
                timestamp(),
                sub(endTime, sload(minAuctionIncrement.slot))
            ) {
                let inc := add(
                    endTime,
                    sload(minAuctionIncrement.slot)
                )
                sstore(add(order.slot, 4), inc)
            }
            sstore(add(order.slot, 6), caller())
            sstore(add(order.slot, 5), callvalue())
        }

        if (lastBidPrice != 0) {
            SafeTransferLib.safeTransferETH(
                order.lastBidder,
                lastBidPrice
            );
        }

        emit Bid(
            order.token,
            order.tokenId,
            _order,
            msg.sender,
            msg.value
        );
    }

    /// @notice Enables user to buy an nft for both Fixed Price and Dutch Auction listings.
    /// @dev Price overrunning not accepted in fixed price and dutch auction.
    /// @dev Function Signature := 0x9c9a1061
    function buy(bytes32 _order)
        external
        payable
        whenNotPaused
    {
        Types.Order721 storage order = orderInfo[_order];

        _buyChecks(
            order.endTime,
            order.orderType,
            order.isSold
        );

        uint256 currentPrice = getCurrentPrice(_order);
        if (msg.value != currentPrice) revert WrongPrice();

        order.isSold = true;

        uint256 key = uint256(
            uint160(address(order.token))
        ) << 12;

        // path for inhouse minted tokens
        if (
            !feeSelector[key][order.tokenId] &&
            MADFactory721.creatorAuth(
                address(order.token),
                order.seller
            ) ==
            true
        ) {
            _intPath(order, currentPrice, _order, msg.sender);
        }
        // path for external tokens
        else {
            // case for external tokens with ERC2981 support
            if (
                ERC165Check(address(order.token)) == true &&
                interfaceCheck(
                    address(order.token),
                    0x2a55205a
                ) ==
                true
            ) {
                _extPath0(
                    order,
                    currentPrice,
                    _order,
                    msg.sender,
                    key
                );
            }
            // case for external tokens without ERC2981 support
            else {
                _extPath1(
                    order,
                    currentPrice,
                    _order,
                    msg.sender,
                    key
                );
            }
        }
    }

    /// @notice Pull method for NFT withdrawing in English Auction.
    /// @dev Function Signature := 0xbd66528a
    /// @dev Callable by both the seller and the auction winner.
    function claim(bytes32 _order) external whenNotPaused {
        Types.Order721 storage order = orderInfo[_order];

        _isBidderOrSeller(order.lastBidder, order.seller);
        _claimChecks(
            order.isSold,
            order.orderType,
            order.endTime
        );

        order.isSold = true;

        uint256 key = uint256(
            uint160(address(order.token))
        ) << 12;

        // path for inhouse minted tokens
        if (
            !feeSelector[key][order.tokenId] &&
            MADFactory721.creatorAuth(
                address(order.token),
                order.seller
            ) ==
            true
        ) {
            _intPath(
                order,
                order.lastBidPrice,
                _order,
                order.lastBidder
            );
        }
        // path for external tokens
        else {
            // case for external tokens with ERC2981 support
            if (
                ERC165Check(address(order.token)) == true &&
                interfaceCheck(
                    address(order.token),
                    0x2a55205a
                ) ==
                true
            ) {
                _extPath0(
                    order,
                    order.lastBidPrice,
                    _order,
                    order.lastBidder,
                    key
                );
            }
            // case for external tokens without ERC2981 support
            else {
                _extPath1(
                    order,
                    order.lastBidPrice,
                    _order,
                    order.lastBidder,
                    key
                );
            }
        }
    }

    /// @notice Enables sellers to withdraw their tokens.
    /// @dev Function Signature := 0x7489ec23
    /// @dev Cancels order setting endTime value to 0.
    function cancelOrder(bytes32 _order) external {
        Types.Order721 storage order = orderInfo[_order];
        _cancelOrderChecks(
            order.seller,
            order.isSold,
            order.lastBidPrice
        );

        IERC721 token = order.token;
        uint256 tokenId = order.tokenId;

        order.endTime = 0;

        token.safeTransferFrom(
            address(this),
            msg.sender,
            tokenId
        );

        emit CancelOrder(token, tokenId, _order, msg.sender);
    }

    receive() external payable {}

    ////////////////////////////////////////////////////////////////
    //                         OWNER FX                           //
    ////////////////////////////////////////////////////////////////

    /// @dev `MADFactory` instance setter.
    /// @dev Function Signature := 0x612990fe
    function setFactory(FactoryVerifier _factory)
        public
        onlyOwner
    {
        assembly {
            // MADFactory721 = _factory;
            sstore(MADFactory721.slot, _factory)
        }
        emit FactoryUpdated(_factory);
    }

    /// @notice Marketplace config setter.
    /// @dev Function Signature := 0x0465c563
    /// @dev Time tracking criteria based on `blocknumber`.
    /// @param _minAuctionIncrement Min. time threshold for Auction extension.
    /// @param _minOrderDuration Min. order listing duration
    /// @param _minBidValue Min. value for a bid to be considered.
    function updateSettings(
        uint256 _minAuctionIncrement,
        uint256 _minOrderDuration,
        uint256 _minBidValue
    ) public onlyOwner {
        // minOrderDuration = _minOrderDuration;
        // minAuctionIncrement = _minAuctionIncrement;
        // minBidValue = _minBidValue;
        assembly {
            sstore(minOrderDuration.slot, _minOrderDuration)
            sstore(
                minAuctionIncrement.slot,
                _minAuctionIncrement
            )
            sstore(minBidValue.slot, _minBidValue)
        }

        emit AuctionSettingsUpdated(
            _minOrderDuration,
            _minAuctionIncrement,
            _minBidValue
        );
    }

    /// @notice Paused state initializer for security risk mitigation pratice.
    /// @dev Function Signature := 0x8456cb59
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpaused state initializer for security risk mitigation pratice.
    /// @dev Function Signature := 0x3f4ba83a
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Enables the contract's owner to change recipient address.
    /// @dev Function Signature := 0x3bbed4a0
    function setRecipient(address _recipient)
        public
        onlyOwner
    {
        // recipient = _recipient;
        assembly {
            sstore(recipient.slot, _recipient)
        }

        emit RecipientUpdated(_recipient);
    }

    /// @dev Function Signature := 0x13af4035
    function setOwner(address newOwner)
        public
        override
        onlyOwner
    {
        // owner = newOwner;
        assembly {
            sstore(owner.slot, newOwner)
        }

        emit OwnerUpdated(msg.sender, newOwner);
    }

    /// @dev Function Signature := 0x3ccfd60b
    function withdraw() external onlyOwner whenPaused {
        SafeTransferLib.safeTransferETH(
            msg.sender,
            address(this).balance
        );
    }

    /// @notice Delete order function only callabe by contract's owner, when contract is paused, as security measure.
    /// @dev Function Signature := 0x0c026db9
    function delOrder(
        bytes32 hash,
        IERC721 _token,
        uint256 _id,
        address _seller
    ) external onlyOwner whenPaused {
        delete orderInfo[hash];
        delete orderIdByToken[_token][_id];
        delete orderIdBySeller[_seller];

        _token.transferFrom(address(this), _seller, _id);
    }

    ////////////////////////////////////////////////////////////////
    //                        INTERNAL FX                         //
    ////////////////////////////////////////////////////////////////

    /// @notice Internal order path resolver.
    /// @dev Function Signature := 0x4ac079a6
    /// @param _orderType Values legend:
    /// 0=Fixed Price; 1=Dutch Auction; 2=English Auction.
    /// @param _endTime Equals to canceled order when value is set to 0.
    function _makeOrder(
        uint8 _orderType,
        IERC721 _token,
        uint256 _id,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _endTime
    ) internal {
        _makeOrderChecks(_endTime, _startPrice);

        bytes32 hash = _hash(_token, _id, msg.sender);
        orderInfo[hash] = Types.Order721(
            _id,
            _startPrice,
            _endPrice,
            block.timestamp,
            _endTime,
            0,
            address(0),
            _token,
            msg.sender,
            _orderType,
            false
        );
        orderIdByToken[_token][_id].push(hash);
        orderIdBySeller[msg.sender].push(hash);

        _token.safeTransferFrom(
            msg.sender,
            address(this),
            _id
        );

        emit MakeOrder(_token, _id, hash, msg.sender);
    }

    /// @notice Provides hash of an order used as an order info pointer
    /// @dev Function Signature := 0x3b1ce0d2
    function _hash(
        IERC721 _token,
        uint256 _id,
        address _seller
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    block.number,
                    _token,
                    _id,
                    _seller
                )
            );
    }

    /// @notice Modified from OpenZeppelin Contracts
    /// (v4.4.1 - utils/introspection/ERC165Checker.sol)
    /// (https://github.com/OpenZeppelin/openzeppelin-contracts)
    function interfaceCheck(
        address account,
        bytes4 interfaceId
    ) internal view returns (bool) {
        bytes memory encodedParams = abi.encodeWithSelector(
            IERC721.supportsInterface.selector,
            interfaceId
        );
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly {
            success := staticcall(
                30000,
                account,
                add(encodedParams, 0x20),
                mload(encodedParams),
                0x00,
                0x20
            )
            returnSize := returndatasize()
            returnValue := mload(0x00)
        }
        return
            success && returnSize >= 0x20 && returnValue > 0;
    }

    /// @notice Modified from OpenZeppelin Contracts
    /// (v4.4.1 - utils/introspection/ERC165Checker.sol)
    /// (https://github.com/OpenZeppelin/openzeppelin-contracts)
    function ERC165Check(address account)
        internal
        view
        returns (bool)
    {
        return
            interfaceCheck(account, 0x01ffc9a7) &&
            !interfaceCheck(account, 0xffffffff);
    }

    function _intPath(
        Types.Order721 storage _order,
        uint256 _price,
        bytes32 _orderId,
        address _to
    ) internal {
        // load royalty info query to mem
        (address _receiver, uint256 _amount) = _order
            .token
            .royaltyInfo(_order.tokenId, _price);
        // transfer royalties
        SafeTransferLib.safeTransferETH(_receiver, _amount);
        // transfer remaining value to seller
        SafeTransferLib.safeTransferETH(
            payable(_order.seller),
            _price - _amount
        );
        // transfer token and emit event
        _order.token.safeTransferFrom(
            address(this),
            _to,
            _order.tokenId
        );
        emit Claim(
            _order.token,
            _order.tokenId,
            _orderId,
            _order.seller,
            _to,
            _price
        );
    }

    function _extPath0(
        Types.Order721 storage _order,
        uint256 _price,
        bytes32 _orderId,
        address _to,
        uint256 key
    ) internal {
        uint16 feePercent = _feeResolver(key, _order.tokenId);
        // load royalty info query to mem
        (address _receiver, uint256 _amount) = _order
            .token
            .royaltyInfo(_order.tokenId, _price);
        // transfer royalties
        SafeTransferLib.safeTransferETH(
            payable(_receiver),
            _amount
        );
        // update price and transfer fee to recipient
        uint256 fee = (_price * feePercent) / basisPoints;
        SafeTransferLib.safeTransferETH(
            payable(recipient),
            fee
        );
        // transfer remaining value to seller
        SafeTransferLib.safeTransferETH(
            payable(_order.seller),
            (_price - (_amount + fee))
        );
        // transfer token and emit event
        _order.token.safeTransferFrom(
            address(this),
            _to,
            _order.tokenId
        );
        emit Claim(
            _order.token,
            _order.tokenId,
            _orderId,
            _order.seller,
            _to,
            _price
        );
    }

    function _extPath1(
        Types.Order721 storage _order,
        uint256 _price,
        bytes32 _orderId,
        address _to,
        uint256 key
    ) internal {
        uint16 feePercent = _feeResolver(key, _order.tokenId);
        uint256 fee = (_price * feePercent) / basisPoints;
        SafeTransferLib.safeTransferETH(
            payable(recipient),
            fee
        );
        SafeTransferLib.safeTransferETH(
            payable(_order.seller),
            _price - fee
        );
        // transfer token and emit event
        _order.token.safeTransferFrom(
            address(this),
            _to,
            _order.tokenId
        );
        emit Claim(
            _order.token,
            _order.tokenId,
            _orderId,
            _order.seller,
            _to,
            _price
        );
    }

    function _feeResolver(uint256 _key, uint256 _tokenId)
        internal
        returns (uint16 _feePercent)
    {
        assembly {
            mstore(0x00, _key)
            mstore(0x20, feeSelector.slot)
            let x := keccak256(0x00, 0x40)
            mstore(0x20, x)
            mstore(0x00, _tokenId)
            let y := keccak256(0x00, 0x40)
            switch sload(y)
            case 0 {
                sstore(y, 1)
                _feePercent := feePercent0
            }
            case 1 {
                _feePercent := feePercent1
            }
        }
    }

    ////////////////////////////////////////////////////////////////
    //                        PRIVATE FX                          //
    ////////////////////////////////////////////////////////////////

    function _exceedsMaxEP(
        uint256 _startPrice,
        uint256 _endPrice
    ) private pure {
        assembly {
            // ExceedsMaxEP()
            if iszero(
                iszero(
                    or(
                        eq(_startPrice, _endPrice),
                        lt(_startPrice, _endPrice)
                    )
                )
            ) {
                mstore(0x00, 0x70f8f33a)
                revert(0x1c, 0x04)
            }
        }
    }

    function _isBidderOrSeller(
        address _bidder,
        address _seller
    ) private view {
        assembly {
            // AccessDenied()
            if iszero(
                or(
                    eq(caller(), _seller),
                    eq(caller(), _bidder)
                )
            ) {
                mstore(0x00, 0x4ca88867)
                revert(0x1c, 0x04)
            }
        }
    }

    function _makeOrderChecks(
        uint256 _endTime,
        uint256 _startPrice
    ) private view {
        assembly {
            // NeedMoreTime()
            if iszero(
                iszero(
                    or(
                        or(
                            eq(timestamp(), _endTime),
                            lt(_endTime, timestamp())
                        ),
                        lt(
                            sub(_endTime, timestamp()),
                            sload(minOrderDuration.slot)
                        )
                    )
                )
            ) {
                mstore(0x00, 0x921dbfec)
                revert(0x1c, 0x04)
            }
            // WrongPrice()
            if iszero(_startPrice) {
                mstore(0x00, 0xf7760f25)
                revert(0x1c, 0x04)
            }
        }
    }

    function _cancelOrderChecks(
        address _seller,
        bool _isSold,
        uint256 _lastBidPrice
    ) private view {
        assembly {
            // AccessDenied()
            if iszero(eq(_seller, caller())) {
                mstore(0x00, 0x4ca88867)
                revert(0x1c, 0x04)
            }
            // SoldToken()
            if iszero(iszero(_isSold)) {
                mstore(0x00, 0xf88b07a3)
                revert(0x1c, 0x04)
            }
            // BidExists()
            if iszero(iszero(_lastBidPrice)) {
                mstore(0x00, 0x3e0827ab)
                revert(0x1c, 0x04)
            }
        }
    }

    function _bidChecks(
        uint8 _orderType,
        uint256 _endTime,
        address _seller,
        uint256 _lastBidPrice,
        uint256 _startPrice
    ) private view {
        assembly {
            // EAOnly()
            if iszero(eq(_orderType, 2)) {
                mstore(0x00, 0xffc96cb0)
                revert(0x1c, 0x04)
            }
            // CanceledOrder()
            if iszero(_endTime) {
                mstore(0x00, 0xdf9428da)
                revert(0x1c, 0x04)
            }
            // Timeout()
            if gt(timestamp(), _endTime) {
                mstore(0x00, 0x2af0c7f8)
                revert(0x1c, 0x04)
            }
            // InvalidBidder()
            if eq(caller(), _seller) {
                mstore(0x00, 0x0863b103)
                revert(0x1c, 0x04)
            }
            // WrongPrice()
            switch iszero(_lastBidPrice)
            case 0 {
                if lt(
                    callvalue(),
                    add(
                        _lastBidPrice,
                        div(
                            _lastBidPrice,
                            sload(minBidValue.slot)
                        )
                    )
                ) {
                    mstore(0x00, 0xf7760f25)
                    revert(0x1c, 0x04)
                }
            }
            case 1 {
                if or(
                    iszero(callvalue()),
                    lt(callvalue(), _startPrice)
                ) {
                    mstore(0x00, 0xf7760f25)
                    revert(0x1c, 0x04)
                }
            }
        }
    }

    function _buyChecks(
        uint256 _endTime,
        uint8 _orderType,
        bool _isSold
    ) private view {
        assembly {
            // CanceledOrder()
            if iszero(_endTime) {
                mstore(0x00, 0xdf9428da)
                revert(0x1c, 0x04)
            }
            // Timeout()
            if or(
                eq(timestamp(), _endTime),
                lt(_endTime, timestamp())
            ) {
                mstore(0x00, 0x2af0c7f8)
                revert(0x1c, 0x04)
            }
            // NotBuyable()
            if eq(_orderType, 0x02) {
                mstore(0x00, 0x07ae5744)
                revert(0x1c, 0x04)
            }
            // SoldToken()
            if iszero(iszero(_isSold)) {
                mstore(0x00, 0xf88b07a3)
                revert(0x1c, 0x04)
            }
        }
    }

    function _claimChecks(
        bool _isSold,
        uint8 _orderType,
        uint256 _endTime
    ) private view {
        assembly {
            // SoldToken()
            if iszero(iszero(_isSold)) {
                mstore(0x00, 0xf88b07a3)
                revert(0x1c, 0x04)
            }
            // EAOnly()
            if iszero(eq(_orderType, 0x02)) {
                mstore(0x00, 0xffc96cb0)
                revert(0x1c, 0x04)
            }
            // NeedMoreTime()
            if or(
                eq(timestamp(), _endTime),
                lt(timestamp(), _endTime)
            ) {
                mstore(0x00, 0x921dbfec)
                revert(0x1c, 0x04)
            }
        }
    }

    ////////////////////////////////////////////////////////////////
    //                   PUBLIC/EXTERNAL GETTERS                  //
    ////////////////////////////////////////////////////////////////

    /// @notice Works as price fetcher of listed tokens
    /// @dev Function Signature := 0x161e444e
    /// @dev Used for price fetching in buy function.
    function getCurrentPrice(bytes32 _order)
        public
        view
        returns (uint256 price)
    {
        Types.Order721 storage order = orderInfo[_order];

        assembly {
            let orderType := shr(
                160,
                sload(add(order.slot, 8))
            )
            mstore(0x80, orderType)
            switch mload(0x80)
            // Fixed Price
            case 0 {
                price := and(
                    sload(add(order.slot, 1)),
                    shr(32, not(0))
                )
            }
            // Ductch Auction
            case 1 {
                let _startPrice := and(
                    sload(add(order.slot, 1)),
                    shr(32, not(0))
                )
                let _startTime := and(
                    sload(add(order.slot, 3)),
                    shr(32, not(0))
                )
                let _endPrice := and(
                    sload(add(order.slot, 2)),
                    shr(32, not(0))
                )
                let _endTime := and(
                    sload(add(order.slot, 4)),
                    shr(32, not(0))
                )
                let _tick := div(
                    sub(_startPrice, _endPrice),
                    sub(_endTime, _startTime)
                )
                price := sub(
                    _startPrice,
                    mul(sub(timestamp(), _startTime), _tick)
                )
            }
            // English Auction
            case 2 {
                let lastBidPrice := and(
                    sload(add(order.slot, 5)),
                    shr(32, not(0))
                )
                switch iszero(lastBidPrice)
                case 1 {
                    price := and(
                        sload(add(order.slot, 1)),
                        shr(32, not(0))
                    )
                }
                case 0 {
                    price := lastBidPrice
                }
            }
        }
    }

    /// @notice Everything in storage can be fetch through the
    /// getters natively provided by all public mappings.
    /// @dev This public getter serve as a hook to ease frontend
    /// fetching whilst estimating `orderIdByToken` indexes by length.
    /// @dev Function Signature := 0x8c5ac795
    function tokenOrderLength(IERC721 _token, uint256 _id)
        external
        view
        returns (uint256)
    {
        return orderIdByToken[_token][_id].length;
    }

    /// @notice Everything in storage can be fetch through the
    /// getters natively provided by all public mappings.
    /// @dev This public getter serve as a hook to ease frontend
    /// fetching whilst estimating `orderIdBySeller` indexes by length.
    /// @dev Function Signature := 0x8aae982a
    function sellerOrderLength(address _seller)
        external
        view
        returns (uint256)
    {
        return orderIdBySeller[_seller].length;
    }
}
