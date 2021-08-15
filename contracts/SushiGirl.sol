// SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/ERC721.sol";
import "./libraries/ERC721Enumerable.sol";
import "./uniswapv2/interfaces/IUniswapV2Pair.sol";
import "./interfaces/IERC1271.sol";
import "./interfaces/ISushiGirl.sol";
import "./libraries/Signature.sol";
import "./interfaces/IMasterChef.sol";

contract SushiGirl is Ownable, ERC721("Sushi Girl", unicode"(◠‿◠🍣)"), ERC721Enumerable, ISushiGirl {
    struct SushiGirlInfo {
        uint256 originPower;
        uint256 supportedLPTokenAmount;
        uint256 sushiRewardDebt;
    }

    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    bytes32 private immutable _TYPE_HASH;

    // keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 public constant override PERMIT_TYPEHASH =
        0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    // keccak256("Permit(address owner,address spender,uint256 nonce,uint256 deadline)");
    bytes32 public constant override PERMIT_ALL_TYPEHASH =
        0xdaab21af31ece73a508939fedd476a5ee5129a5ed4bb091f3236ffb45394df62;

    mapping(uint256 => uint256) public override nonces;
    mapping(address => uint256) public override noncesForAll;

    IUniswapV2Pair public immutable override lpToken;
    uint256 public override lpTokenToSushiGirlPower = 1;
    SushiGirlInfo[] public override sushiGirls;

    IERC20 public immutable override sushi;
    IMasterChef public override sushiMasterChef;
    uint256 public override sushiLastRewardBlock;
    uint256 public override accSushiPerShare;
    bool private initialDeposited;

    constructor(IUniswapV2Pair _lpToken, IERC20 _sushi) {
        lpToken = _lpToken;
        sushi = _sushi;

        _CACHED_CHAIN_ID = block.chainid;
        _HASHED_NAME = keccak256(bytes("Sushi Girl"));
        _HASHED_VERSION = keccak256(bytes("1"));
        _TYPE_HASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

        _CACHED_DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Sushi Girl")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function _baseURI() internal pure override returns (string memory) {
        return "https://api.maidcoin.org/sushigirl/";
    }

    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return keccak256(abi.encode(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
        }
    }

    function changeLPTokenToSushiGirlPower(uint256 value) external onlyOwner {
        lpTokenToSushiGirlPower = value;
        emit ChangeLPTokenToSushiGirlPower(value);
    }

    function mint(uint256 power) external onlyOwner returns (uint256 id) {
        id = sushiGirls.length;
        sushiGirls.push(SushiGirlInfo({originPower: power, supportedLPTokenAmount: 0, sushiRewardDebt: 0}));
        _mint(msg.sender, id);
    }

    function powerOf(uint256 id) external view override returns (uint256) {
        SushiGirlInfo storage sushiGirl = sushiGirls[id];
        return sushiGirl.originPower + (sushiGirl.supportedLPTokenAmount * lpTokenToSushiGirlPower) / 1e18;
    }

    function support(
        uint256 id,
        uint256 lpTokenAmount,
        uint256 pid
    ) public override {
        require(ownerOf(id) == msg.sender, "SushiGirl: Forbidden");
        uint256 _supportedLPTokenAmount = sushiGirls[id].supportedLPTokenAmount;

        sushiGirls[id].supportedLPTokenAmount = _supportedLPTokenAmount + lpTokenAmount;
        lpToken.transferFrom(msg.sender, address(this), lpTokenAmount);

        if (pid > 0) {
            uint256 _totalSupportedLPTokenAmount = sushiMasterChef.userInfo(pid, address(this)).amount;
            uint256 _accSushiPerShare = _depositToSushiMasterChef(pid, lpTokenAmount, _totalSupportedLPTokenAmount);
            uint256 pending = (_supportedLPTokenAmount * _accSushiPerShare) / 1e18 - sushiGirls[id].sushiRewardDebt;
            if (pending > 0) safeSushiTransfer(msg.sender, pending);
            sushiGirls[id].sushiRewardDebt = ((_supportedLPTokenAmount + lpTokenAmount) * _accSushiPerShare) / 1e18;
        }

        emit Support(id, lpTokenAmount);
    }

    function supportWithPermit(
        uint256 id,
        uint256 lpTokenAmount,
        uint256 pid,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        lpToken.permit(msg.sender, address(this), lpTokenAmount, deadline, v, r, s);
        support(id, lpTokenAmount, pid);
    }

    function desupport(
        uint256 id,
        uint256 lpTokenAmount,
        uint256 pid
    ) external override {
        require(ownerOf(id) == msg.sender, "SushiGirl: Forbidden");
        uint256 _supportedLPTokenAmount = sushiGirls[id].supportedLPTokenAmount;

        sushiGirls[id].supportedLPTokenAmount = _supportedLPTokenAmount - lpTokenAmount;
        lpToken.transfer(msg.sender, lpTokenAmount);

        if (pid > 0) {
            uint256 _totalSupportedLPTokenAmount = sushiMasterChef.userInfo(pid, address(this)).amount;
            uint256 _accSushiPerShare = _withdrawFromSushiMasterChef(pid, lpTokenAmount, _totalSupportedLPTokenAmount);
            uint256 pending = (_supportedLPTokenAmount * _accSushiPerShare) / 1e18 - sushiGirls[id].sushiRewardDebt;
            if (pending > 0) safeSushiTransfer(msg.sender, pending);
            sushiGirls[id].sushiRewardDebt = ((_supportedLPTokenAmount + lpTokenAmount) * _accSushiPerShare) / 1e18;
        }

        emit Desupport(id, lpTokenAmount);
    }

    function permit(
        address spender,
        uint256 id,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        require(block.timestamp <= deadline, "SushiGirl: Expired deadline");
        bytes32 _DOMAIN_SEPARATOR = DOMAIN_SEPARATOR();

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, spender, id, nonces[id], deadline))
            )
        );
        nonces[id] += 1;

        address owner = ownerOf(id);
        require(spender != owner, "SushiGirl: Invalid spender");

        if (Address.isContract(owner)) {
            require(
                IERC1271(owner).isValidSignature(digest, abi.encodePacked(r, s, v)) == 0x1626ba7e,
                "SushiGirl: Unauthorized"
            );
        } else {
            address recoveredAddress = Signature.recover(digest, v, r, s);
            require(recoveredAddress == owner, "SushiGirl: Unauthorized");
        }

        _approve(spender, id);
    }

    function permitAll(
        address owner,
        address spender,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        require(block.timestamp <= deadline, "SushiGirl: Expired deadline");
        bytes32 _DOMAIN_SEPARATOR = DOMAIN_SEPARATOR();

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_ALL_TYPEHASH, owner, spender, noncesForAll[owner], deadline))
            )
        );
        noncesForAll[owner] += 1;

        if (Address.isContract(owner)) {
            require(
                IERC1271(owner).isValidSignature(digest, abi.encodePacked(r, s, v)) == 0x1626ba7e,
                "SushiGirl: Unauthorized"
            );
        } else {
            address recoveredAddress = Signature.recover(digest, v, r, s);
            require(recoveredAddress == owner, "SushiGirl: Unauthorized");
        }

        _setApprovalForAll(owner, spender, true);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function setSushiMasterChef(IMasterChef _masterChef) external override onlyOwner {
        require(address(sushiMasterChef) == address(0), "SushiGirl: Already set");
        sushiMasterChef = _masterChef;
    }

    function _depositToSushiMasterChef(
        uint256 _pid,
        uint256 _amount,
        uint256 _totalSupportedLPTokenAmount
    ) internal returns (uint256 _accSushiPerShare) {
        return _toSushiMasterChef(true, _pid, _amount, _totalSupportedLPTokenAmount);
    }

    function _withdrawFromSushiMasterChef(
        uint256 _pid,
        uint256 _amount,
        uint256 _totalSupportedLPTokenAmount
    ) internal returns (uint256 _accSushiPerShare) {
        return _toSushiMasterChef(false, _pid, _amount, _totalSupportedLPTokenAmount);
    }

    function _toSushiMasterChef(
        bool deposit,
        uint256 _pid,
        uint256 _amount,
        uint256 _totalSupportedLPTokenAmount
    ) internal returns (uint256 _accSushiPerShare) {
        uint256 balance0 = sushi.balanceOf(address(this));
        if (deposit) sushiMasterChef.deposit(_pid, _amount);
        else sushiMasterChef.withdraw(_pid, _amount);
        uint256 balance1 = sushi.balanceOf(address(this));
        if (block.number <= sushiLastRewardBlock) {
            return _accSushiPerShare = accSushiPerShare;
        }
        sushiLastRewardBlock = block.number;
        if (_totalSupportedLPTokenAmount > 0) {
            _accSushiPerShare = accSushiPerShare + (((balance1 - balance0) * 1e18) / _totalSupportedLPTokenAmount);
            accSushiPerShare = _accSushiPerShare;
        }
    }

    function initialDepositToSushiMasterChef(uint256 _pid) external override onlyOwner {
        require(!initialDeposited, "SushiGirl: Already deposited");
        initialDeposited = true;
        lpToken.approve(address(sushiMasterChef), type(uint256).max);
        _toSushiMasterChef(true, _pid, lpToken.balanceOf(address(this)), 0);
    }

    function safeSushiTransfer(address _to, uint256 _amount) internal {
        uint256 sushiBal = sushi.balanceOf(address(this));
        if (_amount > sushiBal) {
            sushi.transfer(_to, sushiBal);
        } else {
            sushi.transfer(_to, _amount);
        }
    }
}