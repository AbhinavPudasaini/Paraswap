pragma solidity 0.7.5;



interface IAdapter {

    /**
    * @dev Certain adapters needs to be initialized.
    * This method will be called from Augustus
    */
    function initialize(bytes calldata data) external;

    /**
   * @dev The function which performs the swap on an exchange.
   * @param fromToken Address of the source token
   * @param toToken Address of the destination token
   * @param fromAmount Amount of source tokens to be swapped
   * @param networkFee Network fee to be used in this router
   * @param route Route to be followed
   */
    function swap(
        IERC20 fromToken,
        IERC20 toToken,
        uint256 fromAmount,
        uint256 networkFee,
        Utils.Route[] calldata route
    )
        external
        payable;
}

// File: original_contracts/AugustusStorage.sol

pragma solidity 0.7.5;


contract AugustusStorage {

    struct FeeStructure {
        uint256 partnerShare;
        bool noPositiveSlippage;
        bool positiveSlippageToUser;
        uint16 feePercent;
        string partnerId;
        bytes data;
    }

    ITokenTransferProxy internal tokenTransferProxy;
    address payable internal feeWallet;
    
    mapping(address => FeeStructure) internal registeredPartners;

    mapping (bytes4 => address) internal selectorVsRouter;
    mapping (bytes32 => bool) internal adapterInitialized;
    mapping (bytes32 => bytes) internal adapterVsData;

    mapping (bytes32 => bytes) internal routerData;
    mapping (bytes32 => bool) internal routerInitialized;


    bytes32 public constant WHITELISTED_ROLE = keccak256("WHITELISTED_ROLE");

    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

}

// File: original_contracts/fee/FeeModel.sol

pragma solidity 0.7.5;





contract FeeModel is AugustusStorage {
    using SafeMath for uint256;

    uint256 public immutable partnerSharePercent;
    uint256 public immutable maxFeePercent;

    constructor(
        uint256 _partnerSharePercent,
        uint256 _maxFeePercent
    )
        public
    {
        partnerSharePercent = _partnerSharePercent;
        maxFeePercent = _maxFeePercent;
    }

    function takeFeeAndTransferTokens(
        address toToken,
        uint256 expectedAmount,
        uint256 receivedAmount,
        address payable beneficiary,
        address payable partner,
        uint256 feePercent

    )
        internal
    {
        uint256 remainingAmount = 0;
        uint256 fee = 0;
        
        if ( feePercent > 0 ) {
            FeeStructure memory feeStructure = registeredPartners[partner];
            
            if (feeStructure.partnerShare > 0) {
                fee = _takeFee(
                    feePercent > maxFeePercent ? maxFeePercent : feePercent,
                    toToken,
                    receivedAmount,
                    expectedAmount,
                    feeStructure.partnerShare,
                    feeStructure.noPositiveSlippage,
                    feeStructure.positiveSlippageToUser,
                    partner
                );
            }
            else if (partner != address(0)) {
                fee = _takeFee(
                    feePercent > maxFeePercent ? maxFeePercent : feePercent,
                    toToken,
                    receivedAmount,
                    expectedAmount,
                    partnerSharePercent,
                    false,
                    true,
                    partner
                );
            }
        }

        remainingAmount = receivedAmount.sub(fee);

        //If there is a positive slippage and no partner fee then 50% goes to paraswap and 50% to the user
        if ((remainingAmount > expectedAmount) && fee == 0) {
            uint256 positiveSlippageShare = remainingAmount.sub(expectedAmount).div(2);
            remainingAmount = remainingAmount.sub(positiveSlippageShare);
            Utils.transferTokens(toToken, feeWallet, positiveSlippageShare);
        }

        Utils.transferTokens(toToken, beneficiary, remainingAmount);
    }

    function _takeFee(
        uint256 feePercent,
        address toToken,
        uint256 receivedAmount,
        uint256 expectedAmount,
        uint256 partnerSharePercent,
        bool noPositiveSlippage,
        bool positiveSlippageToUser,
        address payable partner
    )
        private
        returns(uint256 fee)
    {

        uint256 partnerShare = 0;
        uint256 paraswapShare = 0;

        if (!noPositiveSlippage && feePercent <= 50 && receivedAmount > expectedAmount) {
            uint256 halfPositiveSlippage = receivedAmount.sub(expectedAmount).div(2);
            //Calculate total fee to be taken
            fee = expectedAmount.mul(feePercent).div(10000);
            //Calculate partner's share
            partnerShare = fee.mul(partnerSharePercent).div(10000);
            //All remaining fee is paraswap's share
            paraswapShare = fee.sub(partnerShare);
            paraswapShare = paraswapShare.add(halfPositiveSlippage);

            fee = fee.add(halfPositiveSlippage);

            if (!positiveSlippageToUser) {
                partnerShare = partnerShare.add(halfPositiveSlippage);
                fee = fee.add(halfPositiveSlippage);
            }
        }
        else {
            //Calculate total fee to be taken
            fee = receivedAmount.mul(feePercent).div(10000);
            //Calculate partner's share
            partnerShare = fee.mul(partnerSharePercent).div(10000);
            //All remaining fee is paraswap's share
            paraswapShare = fee.sub(partnerShare);
        }
        Utils.transferTokens(toToken, partner, partnerShare);
        Utils.transferTokens(toToken, feeWallet, paraswapShare);

        return (fee);
    }
}

// File: original_contracts/routers/MultiPath.sol

pragma solidity 0.7.5;






contract MultiPath is FeeModel, IRouter {
    using SafeMath for uint256;

    constructor(
        uint256 _partnerSharePercent,
        uint256 _maxFeePercent
    )
        FeeModel(
            _partnerSharePercent,
            _maxFeePercent
        )
        public
    {

    }

    function initialize(bytes calldata data) override external {
        revert("METHOD NOT IMPLEMENTED");
    }

    function getKey() override external pure returns(bytes32) {
        return keccak256(abi.encodePacked("MULTIPATH_ROUTER", "1.0.0"));
    }

    /**
   * @dev The function which performs the multi path swap.
   * @param data Data required to perform swap.
   */
    function multiSwap(
        Utils.SellData memory data
    )
        public
        payable
        returns (uint256)
    {   
        require(data.deadline >= block.timestamp, "Deadline breached");

        address fromToken = data.fromToken;
        uint256 fromAmount = data.fromAmount;
        uint256 toAmount = data.toAmount;
        uint256 expectedAmount = data.expectedAmount;
        address payable beneficiary = data.beneficiary == address(0) ? msg.sender : data.beneficiary;
        Utils.Path[] memory path = data.path;
        address toToken = path[path.length - 1].to;

        require(toAmount > 0, "To amount can not be 0");

        //If source token is not ETH than transfer required amount of tokens
        //from sender to this contract
        transferTokensFromProxy(fromToken, fromAmount, data.permit);

        performSwap(
            fromToken,
            fromAmount,
            path
        );


        uint256 receivedAmount = Utils.tokenBalance(
            toToken,
            address(this)
        );

        require(
            receivedAmount >= toAmount,
            "Received amount of tokens are less then expected"
        );


        takeFeeAndTransferTokens(
            toToken,
            expectedAmount,
            receivedAmount,
            beneficiary,
            data.partner,
            data.feePercent
        );

        emit Swapped(
            data.uuid,
            msg.sender,
            beneficiary,
            fromToken,
            toToken,
            fromAmount,
            receivedAmount,
            expectedAmount
        );

        return receivedAmount;
    }

    /**
   * @dev The function which performs the mega path swap.
   * @param data Data required to perform swap.
   */
    function megaSwap(
        Utils.MegaSwapSellData memory data
    )
        public
        payable
        returns (uint256)
    {
        require(data.deadline >= block.timestamp, "Deadline breached");
        address fromToken = data.fromToken;
        uint256 fromAmount = data.fromAmount;
        uint256 toAmount = data.toAmount;
        uint256 expectedAmount = data.expectedAmount;
        address payable beneficiary = data.beneficiary == address(0) ? msg.sender : data.beneficiary;
        Utils.MegaSwapPath[] memory path = data.path;
        address toToken = path[0].path[path[0].path.length - 1].to;

        require(toAmount > 0, "To amount can not be 0");

        //if fromToken is not ETH then transfer tokens from user to this contract
        transferTokensFromProxy(fromToken, fromAmount, data.permit);

        for (uint8 i = 0; i < uint8(path.length); i++) {
            uint256 _fromAmount = fromAmount.mul(path[i].fromAmountPercent).div(10000);
            if (i == path.length - 1) {
                _fromAmount = Utils.tokenBalance(address(fromToken), address(this));
            }
            performSwap(
                fromToken,
                _fromAmount,
                path[i].path
            );
        }

        uint256 receivedAmount = Utils.tokenBalance(
            toToken,
            address(this)
        );

        require(
            receivedAmount >= toAmount,
            "Received amount of tokens are less then expected"
        );


        takeFeeAndTransferTokens(
            toToken,
            expectedAmount,
            receivedAmount,
            beneficiary,
            data.partner,
            data.feePercent
        );

        emit Swapped(
            data.uuid,
            msg.sender,
            beneficiary,
            fromToken,
            toToken,
            fromAmount,
            receivedAmount,
            expectedAmount
        );

        return receivedAmount;
    }

    //Helper function to perform swap
    function performSwap(
        address fromToken,
        uint256 fromAmount,
        Utils.Path[] memory path
    )
        private
    {

        require(path.length > 0, "Path not provided for swap");

        //Assuming path will not be too long to reach out of gas exception
        for (uint i = 0; i < path.length; i++) {
            //_fromToken will be either fromToken or toToken of the previous path
            address _fromToken = i > 0 ? path[i - 1].to : fromToken;
            address _toToken = path[i].to;

            uint256 _fromAmount = i > 0 ? Utils.tokenBalance(_fromToken, address(this)) : fromAmount;
            if (i > 0 && _fromToken == Utils.ethAddress()) {
                _fromAmount = _fromAmount.sub(path[i].totalNetworkFee);
            }

            for (uint j = 0; j < path[i].adapters.length; j++) {
                Utils.Adapter memory adapter = path[i].adapters[j];

                //Check if exchange is supported
                require(
                    IAugustusSwapperV5(address(this)).hasRole(WHITELISTED_ROLE, adapter.adapter),
                    "Exchange not whitelisted"
                );

                //Calculating tokens to be passed to the relevant exchange
                //percentage should be 200 for 2%
                uint fromAmountSlice = _fromAmount.mul(adapter.percent).div(10000);
                uint256 value = adapter.networkFee;

                if (i > 0 && j == path[i].adapters.length.sub(1)) {
                    uint256 remBal = Utils.tokenBalance(address(_fromToken), address(this));

                    fromAmountSlice = remBal;

                    if (address(_fromToken) == Utils.ethAddress()) {
                        //subtract network fee
                        fromAmountSlice = fromAmountSlice.sub(value);
                    }
                }

                //DELEGATING CALL TO THE ADAPTER
                (bool success,) = adapter.adapter.delegatecall(
                    abi.encodeWithSelector(
                        IAdapter.swap.selector,
                        _fromToken,
                        _toToken,
                        fromAmountSlice,
                        adapter.networkFee,
                        adapter.route
                    )
                );

                require(success, "Call to adapter failed");
            }
        }
    }

    function transferTokensFromProxy(
        address token,
        uint256 amount,
        bytes memory permit
    )
      private
    {
        if (token != Utils.ethAddress()) {
            Utils.permit(token, permit);
            tokenTransferProxy.transferFrom(
                token,
                msg.sender,
                address(this),
                amount
            );
        }
    }
}