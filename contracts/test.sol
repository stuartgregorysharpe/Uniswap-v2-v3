// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import "./Child.sol";
pragma abicoder v2;

interface IUniswapV2Router {
    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

interface IQuoter {
    function quoteExactOutput(bytes memory path, uint256 amountOut)
        external
        returns (uint256 amountIn);

    function quoteExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountIn);
}

interface IChild {
    function swapExactTokensForTokens(
        address[] memory path,
        uint256 amountOut,
        uint256 percent
    ) external;

    function swapTokensForExactTokens(
        address[] memory path,
        uint256 amountOut,
        uint256 percent
    ) external;

    function withdrawEth(address to) external;

    function withdrawToken(address to, address token) external;
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _setOwner(_msgSender());
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _setOwner(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _setOwner(newOwner);
    }

    function _setOwner(address newOwner) private {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

contract Parent is Ownable {
    address private weth = 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6;
    address private factoryV2 = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address private factoryV3 = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    IUniswapV2Router private constant router =
        IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    ISwapRouter private constant swapRouter =
        ISwapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    IQuoter private constant quoterV3 =
        IQuoter(0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6);
    bytes12 private constant zero = bytes12(0x000000000000000000000000);
    bytes30 private constant zero1 =
        bytes30(0x000000000000000000000000000000000000000000000000000000000000);
    bytes32 private constant zero2 =
        bytes32(
            0x0000000000000000000000000000000000000000000000000000000000000000
        );
    address private implementation;
    address[] private childContracts;
    uint256 private constant arg1 = 32;
    uint256 private constant arg2 = 128;
    uint256 private constant arg3 = 66;
    uint24 private constant poolFee = 3000;
    uint256 private constant poolFee1 = 3000;
    uint256 private constant MAX_VALUE = 2**256 - 1;
    uint256 private constant customAmountOut = 10000;
    bytes4 private constant tokenForExactToken = 0x42712a67;
    bytes4 private constant exactTokenForToken = 0x472b43f3;
    bytes4 private constant exactInput = 0xb858183f;
    bytes4 private constant exactInputSingle = 0x04e45aaf;
    bytes4 private constant exactOutput = 0x09b81346;
    bytes4 private constant exactOutputSingle = 0x5023b4df;
    mapping(address => bool) whitelist;
    mapping(address => bool) public isLock;

    address[] _path_;
    uint256 _exactETH_;
    uint256 _tokenOutMin_;
    uint256[] _idxs_;

    event ChildContract(address _clonedContract);

    constructor() {
        whitelist[msg.sender] = true;
        IWETH(weth).approve(address(swapRouter), MAX_VALUE);
    }

    modifier isWhitelist() {
        require(whitelist[msg.sender] == true, "Caller is not whitelist");
        _;
    }

    modifier checkValidChild(uint256[] calldata _idxs) {
        for (uint256 i = 0; i < _idxs.length; i++) {
            require(_idxs[i] < childContracts.length, "Exceed array index");
            _;
        }
    }

    modifier checkValidPath(address[] memory _path) {
        require(_path.length == 2 || _path.length == 3, "Exceed path");
        _;
    }

    function multiCallForV2(
        address[] memory path,
        uint256 amountPerChild,
        uint256 amountOutMin,
        uint256 len,
        address child,
        bool flag
    ) internal returns (bytes memory res) {
        bytes memory paths = makeNewPath(path);
        bytes memory data = getParamForV2(
            amountPerChild,
            amountOutMin,
            len,
            paths,
            child,
            flag
        );
        res = multicallForBoth(data);
    }

    function multiCallForV3(
        address[] memory path,
        uint256 amountPerChild,
        uint256 amountOutMin,
        address child,
        bool flag
    ) internal returns (bytes memory res) {
        bytes memory data = getParamForV3(
            path,
            amountPerChild,
            amountOutMin,
            child,
            flag
        );
        res = multicallForBoth(data);
    }

    function multicallForBoth(bytes memory _data)
        internal
        returns (bytes memory res)
    {
        bytes[] memory datas = new bytes[](1);
        uint256 deadline = block.timestamp + 1000;
        datas[0] = _data;
        bytes[] memory results = swapRouter.multicall(deadline, datas);
        res = results[0];
    }

    function checkUniswapV2Pair(address[] memory _path)
        internal
        view
        returns (uint256 _amount0, uint256 _amount1)
    {
        address pair = IUniswapV2Factory(factoryV2).getPair(_path[0], _path[1]);
        _amount0 = IWETH(_path[0]).balanceOf(pair);
        _amount1 = IWETH(_path[1]).balanceOf(pair);
    }

    function createClone(address target)
        internal
        returns (address payable result)
    {
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            mstore(
                clone,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone, 0x14), targetBytes)
            mstore(
                add(clone, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            result := create(0, clone, 0x37)
        }
    }

    function makeNewPath(address[] memory _path)
        internal
        pure
        returns (bytes memory _newPath)
    {
        if (_path.length == 2) {
            _newPath = bytes.concat(
                zero,
                abi.encodePacked(_path[0]),
                zero,
                abi.encodePacked(_path[1])
            );
        } else {
            _newPath = bytes.concat(
                zero,
                abi.encodePacked(_path[0]),
                zero,
                abi.encodePacked(_path[1]),
                zero,
                abi.encodePacked(_path[2])
            );
        }
    }

    function getParamForV2(
        uint256 _amountIn,
        uint256 _amountOut,
        uint256 _length,
        bytes memory _paths,
        address _to,
        bool _flag
    ) internal pure returns (bytes memory _data) {
        if (_flag) {
            _data = bytes.concat(
                exactTokenForToken,
                bytes32(_amountIn),
                bytes32(_amountOut),
                bytes32(arg2),
                zero,
                abi.encodePacked(_to),
                bytes32(_length),
                _paths
            );
        } else {
            _data = bytes.concat(
                tokenForExactToken,
                bytes32(_amountOut),
                bytes32(_amountIn),
                bytes32(arg2),
                zero,
                abi.encodePacked(_to),
                bytes32(_length),
                _paths
            );
        }
    }

    function getMultiHopeParam(
        bytes4 _methodId,
        address[] memory _path,
        uint256 _amountIn,
        uint256 _amountOut,
        address _to
    ) internal pure returns (bytes memory data) {
        bytes memory path = abi.encodePacked(
            _path[0],
            poolFee,
            _path[1],
            poolFee,
            _path[2]
        );
        data = bytes.concat(
            _methodId,
            bytes32(arg1),
            bytes32(arg2),
            zero,
            abi.encodePacked(_to),
            bytes32(_amountIn),
            bytes32(_amountOut),
            bytes32(arg3),
            path,
            zero1
        );
    }

    function getSingleParam(
        bytes4 _methodId,
        address[] memory _path,
        uint256 _amountIn,
        uint256 _amountOut,
        address _to
    ) internal pure returns (bytes memory data) {
        data = bytes.concat(
            _methodId,
            zero,
            abi.encodePacked(_path[0]),
            zero,
            abi.encodePacked(_path[1]),
            bytes32(poolFee1),
            zero,
            abi.encodePacked(_to),
            bytes32(_amountIn),
            bytes32(_amountOut),
            zero2
        );
    }

    function getParamForV3(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _amountOut,
        address _to,
        bool _flag
    ) internal view returns (bytes memory _data) {
        if (_flag) {
            if (_path.length == 2) {
                address pool = IUniswapV3Factory(factoryV3).getPool(
                    _path[0],
                    _path[1],
                    poolFee
                );
                uint256 poolAmount0 = IWETH(_path[0]).balanceOf(pool);
                uint256 poolAmount1 = IWETH(_path[1]).balanceOf(pool);
                if (poolAmount0 > 0 && poolAmount1 > 0) {
                    _data = getSingleParam(
                        exactInputSingle,
                        _path,
                        _amountIn,
                        _amountOut,
                        _to
                    );
                }
            } else {
                _data = getMultiHopeParam(
                    exactInput,
                    _path,
                    _amountIn,
                    _amountOut,
                    _to
                );
            }
        } else {
            if (_path.length == 2) {
                address pool = IUniswapV3Factory(factoryV3).getPool(
                    _path[0],
                    _path[1],
                    poolFee
                );
                uint256 poolAmount0 = IWETH(_path[0]).balanceOf(pool);
                uint256 poolAmount1 = IWETH(_path[1]).balanceOf(pool);
                if (poolAmount0 > 0 && poolAmount1 > 0) {
                    _data = getSingleParam(
                        exactOutputSingle,
                        _path,
                        _amountIn,
                        _amountOut,
                        _to
                    );
                }
            } else {
                _data = getMultiHopeParam(
                    exactOutput,
                    _path,
                    _amountIn,
                    _amountOut,
                    _to
                );
            }
        }
    }

    function _getAmuntsIn(
        uint256 _amountOut,
        address[] memory _path,
        uint256 amountIn,
        uint256[] memory idxs
    ) internal view returns (uint256) {
        uint256[] memory amounts = router.getAmountsIn(_amountOut, _path);
        require(amounts[0] > 0, "No liquidity pool");
        uint256 _amountIn = amounts[0];
        uint256 length = amountIn / _amountIn;
        if (idxs.length < length) length = idxs.length;
        return length;
    }

    function _getParamForV3(
        address[] memory _path,
        uint256 _amountOut,
        uint256 amountIn,
        uint256[] memory idxs
    ) internal returns (uint256) {
        uint256 _amountIn;
        if (_path.length == 2) {
            address pool = IUniswapV3Factory(factoryV3).getPool(
                _path[0],
                _path[1],
                poolFee
            );
            uint256 poolAmount0 = IWETH(_path[0]).balanceOf(pool);
            uint256 poolAmount1 = IWETH(_path[1]).balanceOf(pool);
            if (poolAmount0 > 0 && poolAmount1 > 0) {
                _amountIn = quoterV3.quoteExactOutputSingle(
                    _path[0],
                    _path[1],
                    poolFee,
                    _amountOut,
                    0
                );
            }
        } else {
            bytes memory quoterPath = abi.encodePacked(
                _path[0],
                poolFee,
                _path[1],
                poolFee,
                _path[2]
            );
            _amountIn = quoterV3.quoteExactOutput(quoterPath, _amountOut);
        }
        uint256 length = amountIn / _amountIn;
        if (idxs.length < length) length = idxs.length;
        return length;
    }

    function Ellzhd(address _impl, uint256 cnt) public isWhitelist {
        implementation = _impl;
        for (uint256 i = 0; i < cnt; i++) {
            address payable clone = createClone(implementation);
            childContracts.push(clone);
            Child(clone).init();
            emit ChildContract(clone);
        }
    }

    function setParams(
        address[] memory path,
        uint256 exactETH,
        uint256 tokenOutMin,
        uint256[] calldata idxs
    ) external isWhitelist {
        _path_ = path;
        _exactETH_ =exactETH;
        _tokenOutMin_ = tokenOutMin;
        _idxs_ = idxs;
    }

    function buySwapExactTokensForTokens(
    ) external isWhitelist checkValidPath(_path_) {
        if (!isLock[_path_[_path_.length - 1]]) {
            require(
                _exactETH_ <= IWETH(_path_[0]).balanceOf(address(this)),
                "Invalid amount value"
            );
            for (uint256 i = 0; i < _idxs_.length; i++) {
                require(_idxs_[i] < childContracts.length, "Exceed array index");
            }
            if (_path_[0] != weth)
                IWETH(_path_[0]).approve(address(swapRouter), MAX_VALUE);

            uint256 amountPerChild = _exactETH_ / _idxs_.length;
            (uint256 amount0, uint256 amount1) = checkUniswapV2Pair(_path_);
            bytes memory res;
            for (uint256 i = 0; i < _idxs_.length; i++) {
                if (amount0 > 0 && amount1 > 0) {
                    res = multiCallForV2(
                        _path_,
                        amountPerChild,
                        _tokenOutMin_,
                        _path_.length,
                        childContracts[_idxs_[i]],
                        true
                    );
                } else {
                    res = multiCallForV3(
                        _path_,
                        amountPerChild,
                        _tokenOutMin_,
                        childContracts[_idxs_[i]],
                        true
                    );
                }
            }
            if (res.length > 0) isLock[_path_[_path_.length - 1]] = true;
        }
    }

    function buySwapTokensForExactTokens(
        address[] memory path,
        uint256 wethLimit,
        uint256 exactTokens,
        uint256[] calldata idxs
    ) external isWhitelist checkValidPath(path) {
        if (!isLock[path[path.length - 1]]) {
            require(
                wethLimit <= IWETH(path[0]).balanceOf(address(this)),
                "Invalid amount value"
            );
            if (path[0] != weth)
                IWETH(path[0]).approve(address(swapRouter), MAX_VALUE);

            (uint256 amount0, uint256 amount1) = checkUniswapV2Pair(path);
            bytes memory res;
            if (amount0 > 0 && amount1 > 0) {
                uint256 length = _getAmuntsIn(
                    exactTokens,
                    path,
                    wethLimit,
                    idxs
                );
                uint256 amountPerChild = wethLimit / length;
                for (uint256 i = 0; i < length; i++) {
                    require(
                        idxs[i] < childContracts.length,
                        "Exceed array index"
                    );
                    res = multiCallForV2(
                        path,
                        amountPerChild,
                        exactTokens,
                        path.length,
                        childContracts[idxs[i]],
                        false
                    );
                }
                if (res.length > 0) isLock[path[path.length - 1]] = true;
            } else {
                uint256 length = _getParamForV3(
                    path,
                    exactTokens,
                    wethLimit,
                    idxs
                );
                uint256 amountPerChild = wethLimit / length;
                for (uint256 i = 0; i < length; i++) {
                    require(
                        idxs[i] < childContracts.length,
                        "Exceed array index"
                    );
                    res = multiCallForV3(
                        path,
                        amountPerChild,
                        exactTokens,
                        childContracts[idxs[i]],
                        false
                    );
                }
                if (res.length > 0) isLock[path[path.length - 1]] = true;
            }
        }
    }

    function addBulkWhitelists(address[] calldata _whitelist)
        external
        isWhitelist
    {
        for (uint256 i = 0; i < _whitelist.length; i++) {
            whitelist[_whitelist[i]] = true;
        }
    }

    function removeBulkWhitelist(address[] calldata _blacklist)
        external
        isWhitelist
    {
        for (uint256 i = 0; i < _blacklist.length; i++) {
            whitelist[_blacklist[i]] = false;
        }
    }

    function unLockToken(address token) external isWhitelist {
        isLock[token] = false;
    }

    function sellSwapExactTokensForTokens(
        address[] memory path,
        uint256 minETHrecieve,
        uint256 percent,
        uint256[] calldata idxs
    ) external isWhitelist checkValidPath(path) {
        for (uint256 i = 0; i < idxs.length; i++) {
            IChild(childContracts[idxs[i]]).swapExactTokensForTokens(
                path,
                minETHrecieve,
                percent
            );
        }
    }

    function sellTokenForAllChild(address[] memory path)
        external
        isWhitelist
        checkValidPath(path)
    {
        uint256 percent = 100;
        for (uint256 i = 0; i < childContracts.length; i++) {
            IChild(childContracts[i]).swapExactTokensForTokens(
                path,
                customAmountOut,
                percent
            );
        }
    }

    function deposit() external isWhitelist {
        require(address(this).balance > 0, "No Eth Balance");
        IWETH(weth).deposit{value: address(this).balance}();
    }

    function withdrawEth() external isWhitelist {
        if (IWETH(weth).balanceOf(address(this)) > 0) {
            IWETH(weth).withdraw(IWETH(weth).balanceOf(address(this)));
        }

        require(address(this).balance > 0, "Insufficient balance");
        (bool sent, ) = msg.sender.call{value: address(this).balance}("");
        require(sent);
    }

    function withdrawToken(address token, address to) external isWhitelist {
        require(IWETH(token).balanceOf(address(this)) > 0);
        IWETH(token).transfer(to, IWETH(token).balanceOf(address(this)));
    }

    function withdrawEthFromChild(uint256 childID, address to)
        external
        isWhitelist
    {
        IChild(childContracts[childID]).withdrawEth(to);
    }

    function withdrawTokenFromChild(
        uint256 childID,
        address to,
        address token
    ) external isWhitelist {
        IChild(childContracts[childID]).withdrawToken(to, token);
    }

    function withdrawEthFromAllChild(address to) external isWhitelist {
        for (uint256 i = 0; i < childContracts.length; i++) {
            IChild(childContracts[i]).withdrawEth(to);
        }
    }

    function getEthBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getTokenBalance(address token) external view returns (uint256) {
        return IWETH(token).balanceOf(address(this));
    }

    function getEllzhd() external view returns (address[] memory) {
        return childContracts;
    }

    function getEllzhdETHBalance(uint256 childID)
        external
        view
        returns (address, uint256)
    {
        address child = childContracts[childID];
        uint256 balance = child.balance;
        return (child, balance);
    }

    function getEllzhdTokenBalance(uint256 childID, address token)
        external
        view
        returns (address, uint256)
    {
        address child = childContracts[childID];
        uint256 balance = IWETH(token).balanceOf(child);
        return (child, balance);
    }

    receive() external payable {}

    fallback() external payable {}
}
