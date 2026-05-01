// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @notice Renderer contract that knows how to turn a Cert into a tokenURI. EvalCert
///         delegates rendering so the art can be hot-swapped without redeploying.
interface IEvalCertRenderer {
    function tokenURI(uint256 tokenId, EvalCert.Cert memory cert) external view returns (string memory);
}

/// @title  EvalCert — PropFund Certificates (Eval Pass + Level Up NFTs)
/// @author PropFund
/// @notice Minimal ERC-721 used by PropFund to commemorate eval passes and funded-trader
///         level-ups. Cert data lives on this contract; SVG rendering is delegated to a
///         hot-swappable renderer (EvalCertRenderer) so the visual design can iterate
///         without redeploying the NFT — existing tokens automatically reflect the new art.
/// @dev Mint-only by PropFund (MINTER, set at deploy from the constructor caller). Admin
///      (set at construction, settable later) can swap the renderer or hand off admin.
///      Transfer/approval functions are NOT implemented — these are non-transferable
///      proof-of-achievement tokens. Only the Transfer event from mint is emitted.
contract EvalCert {
    /// @notice Caller is not the PropFund contract that constructed this NFT.
    error NotMinter();
    /// @notice Caller is not the admin authorised to manage renderer/admin.
    error NotAdmin();
    /// @notice tokenURI called for a token that has never been minted.
    error NotOwner();
    /// @notice tokenURI called before a renderer has been wired in.
    error NoRenderer();
    /// @notice Address argument was zero in a context that disallows it.
    error ZeroAddress();

    /// @notice ERC-721 mint event. Emitted only on mint (no transfers; tokens are SBTs).
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    /// @notice Emitted when admin swaps the SVG renderer.
    event RendererSet(address indexed renderer);
    /// @notice Emitted on construction and on admin handover.
    event AdminSet(address indexed admin);

    string public constant name = "PropFund Certificate";
    string public constant symbol = "PFCERT";

    /// @notice The only address allowed to call mint(). Set to the PropFund contract that
    ///         deployed this EvalCert (msg.sender at construction).
    address public immutable MINTER;
    /// @notice Admin can swap the renderer to ship new art and hand off admin.
    address public admin;
    /// @notice Active SVG renderer. Reads cert data + queries PropFund to draw the chart.
    address public renderer;

    /// @notice ERC-721 totals + ownership maps. Approvals are unused (tokens are non-transferable).
    uint256 public totalSupply;
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /// @notice EVAL_PASS = mint after passing eval; LEVEL_UP = mint after crossing a
    ///         cumulative-PnL milestone as a funded trader.
    enum CertType { EVAL_PASS, LEVEL_UP }

    /// @notice Per-token data. Stored on-chain so renderer can derive the SVG without
    ///         reading any other source.
    /// @param trader   The recipient — also the address whose stats the renderer reads.
    /// @param passBlock block.number at mint (used as procedural-art seed + footer text).
    /// @param value    For EVAL_PASS: the trader's virtualBalance at pass (1e18-scaled,
    ///                 e.g. 1.08e18 = +8.0%). For LEVEL_UP: cumulativePnl in 6-decimal USDC.
    /// @param certType EVAL_PASS or LEVEL_UP.
    /// @param level    Funded-trader leverage tier reached (LEVEL_UP only; 0 for EVAL_PASS).
    struct Cert {
        address trader;
        uint256 passBlock;
        uint256 value;
        CertType certType;
        uint8 level;
    }
    mapping(uint256 => Cert) public certs;

    /// @param _admin Initial admin (may swap renderer + hand off admin later).
    constructor(address _admin) {
        if (_admin == address(0)) revert ZeroAddress();
        MINTER = msg.sender;
        admin = _admin;
        emit AdminSet(_admin);
    }

    /*//////////////////////////////////////////////////////////////
                          MINT (PropFund only)
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint a cert. Callable only by MINTER (the PropFund contract).
    /// @param trader   Recipient; also the address whose stats the renderer reads at view time.
    /// @param value    See Cert.value.
    /// @param certType EVAL_PASS or LEVEL_UP.
    /// @param level    Leverage tier (0 for EVAL_PASS).
    /// @return tokenId Newly-minted id (1-indexed).
    function mint(address trader, uint256 value, CertType certType, uint8 level) external returns (uint256 tokenId) {
        if (msg.sender != MINTER) revert NotMinter();
        tokenId = totalSupply + 1;
        totalSupply = tokenId;
        ownerOf[tokenId] = trader;
        unchecked { balanceOf[trader] += 1; }
        certs[tokenId] = Cert(trader, block.number, value, certType, level);
        emit Transfer(address(0), trader, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                       ADMIN (renderer hot-swap)
    //////////////////////////////////////////////////////////////*/

    /// @notice Swap the SVG renderer. Existing tokens immediately reflect the new design.
    /// @param _renderer Non-zero address of an IEvalCertRenderer-compatible contract.
    function setRenderer(address _renderer) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_renderer == address(0)) revert ZeroAddress();
        renderer = _renderer;
        emit RendererSet(_renderer);
    }

    /// @notice Hand off admin. Use a multisig for production deployments.
    /// @param _admin New admin (non-zero).
    function setAdmin(address _admin) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
        emit AdminSet(_admin);
    }

    /*//////////////////////////////////////////////////////////////
                            METADATA
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-721 metadata. Returns a `data:application/json;base64,...` URI built by
    ///         the active renderer.
    /// @param tokenId Existing token id (1..totalSupply).
    /// @return JSON+SVG data URI suitable for OpenSea-style consumers.
    /// @dev Reverts NotOwner if tokenId was never minted, NoRenderer if renderer hasn't
    ///      been wired up.
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        Cert memory c = certs[tokenId];
        if (c.trader == address(0)) revert NotOwner();
        if (renderer == address(0)) revert NoRenderer();
        return IEvalCertRenderer(renderer).tokenURI(tokenId, c);
    }
}
