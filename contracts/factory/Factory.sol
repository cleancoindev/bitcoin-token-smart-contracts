pragma solidity 0.4.24;


import "../utils/OwnableContract.sol";
import "../controller/ControllerInterface.sol";


contract Factory is OwnableContract {

    enum RequestStatus {PENDING, CANCELED, APPROVED, REJECTED}

    struct Request {
        address requester; // sender of the request.
        uint amount;
        string btcDepositAddress; // custodian's btc address in mint, merchant's btc address for burn.
        string btcTxid;
        uint nonce;
        uint timestamp;
        RequestStatus status;
    }

    ControllerInterface public controller;

    // mapping between merchant to the corresponding custodian deposit address, used in the minting process.
    // by using a different deposit address per merchant the custodian can identify which merchant deposited.
    // all custodians are assumed to use the same deposit address per merchant.
    mapping(address=>string) public custodianBtcDepositAddress;

    // mapping between merchant to the its deposit address where btc should be moved to, used in the burning process.
    mapping(address=>string) public merchantBtcDepositAddress;

    // mapping between a mint request hash and the corresponding request nonce. 
    mapping(bytes32=>uint) public mintRequestNonce;

    // mapping between a burn request hash and the corresponding request nonce.
    mapping(bytes32=>uint) public burnRequestNonce;

    Request[] public mintRequests;
    Request[] public burnRequests;

    constructor(ControllerInterface _controller) public {
        require(_controller != address(0), "invalid _controller address");
        controller = _controller;
    }

    modifier onlyMerchant() {
        require(controller.isMerchant(msg.sender), "sender not a merchant.");
        _;
    }

    modifier onlyCustodian() {
        require(controller.isCustodian(msg.sender), "sender not a custodian.");
        _;
    }

    event CustodianBtcDepositAddressSet(address indexed merchant, string btcDepositAddress, address sender);

    function setCustodianBtcDepositAddress(address merchant, string btcDepositAddress) external onlyCustodian {
        require(merchant != 0, "merchant address is 0");
        require(!isEmptyString(btcDepositAddress), "invalid btc deposit address");

        custodianBtcDepositAddress[merchant] = btcDepositAddress;
        emit CustodianBtcDepositAddressSet(merchant, btcDepositAddress, msg.sender);
    }

    event MerchantBtcDepositAddressSet(address indexed merchant, string btcDepositAddress);

    function setMerchantBtcDepositAddress(string btcDepositAddress) external onlyMerchant {
        require(!isEmptyString(btcDepositAddress), "invalid btc deposit address");

        merchantBtcDepositAddress[msg.sender] = btcDepositAddress;
        emit MerchantBtcDepositAddressSet(msg.sender, btcDepositAddress); 
    }

    event MintRequestAdd(
        uint indexed nonce,
        address indexed requester,
        uint amount,
        string btcDepositAddress,
        string btcTxid,
        uint timestamp,
        bytes32 requestHash
    );

    function addMintRequest(uint amount, string btcTxid, string btcDepositAddress) external onlyMerchant {
        require(!isEmptyString(btcDepositAddress), "invalid btc deposit address"); 
        require(compareStrings(btcDepositAddress, custodianBtcDepositAddress[msg.sender]), "wrong btc deposit address");

        uint nonce = mintRequests.length;
        uint timestamp = getTimestamp();

        Request memory request = Request({
            requester: msg.sender,
            amount: amount,
            btcDepositAddress: btcDepositAddress,
            btcTxid: btcTxid,
            nonce: nonce,
            timestamp: timestamp,
            status: RequestStatus.PENDING
        });

        bytes32 requestHash = calcRequestHash(request);
        mintRequestNonce[requestHash] = nonce; 
        mintRequests.push(request);

        emit MintRequestAdd(nonce, msg.sender, amount, btcDepositAddress, btcTxid, timestamp, requestHash);
    }

    event Burned(
        uint indexed nonce,
        address indexed requester,
        uint amount,
        string btcDepositAddress,
        uint timestamp,
        bytes32 requestHash
    );

    function burn(uint amount) external onlyMerchant {
        string memory btcDepositAddress = merchantBtcDepositAddress[msg.sender];
        require(!isEmptyString(btcDepositAddress), "merchant btc deposit address was not set"); 

        uint nonce = burnRequests.length;
        uint timestamp = getTimestamp();

        string memory btcTxid = ""; // set txid as empty since it is not known yet

        Request memory request = Request({
            requester: msg.sender,
            amount: amount,
            btcDepositAddress: btcDepositAddress,
            btcTxid: btcTxid,
            nonce: nonce,
            timestamp: timestamp,
            status: RequestStatus.PENDING
        });

        bytes32 requestHash = calcRequestHash(request);
        burnRequestNonce[requestHash] = nonce; 
        burnRequests.push(request);

        require(controller.getWBTC().transferFrom(msg.sender, controller, amount), "trasnfer tokens to burn failed");
        require(controller.burn(amount), "burn failed");

        emit Burned(nonce, msg.sender, amount, btcDepositAddress, timestamp, requestHash);
    }

    event MintConfirmed(
        uint indexed nonce,
        address indexed requester,
        uint amount,
        string btcDepositAddress,
        string btcTxid,
        uint timestamp,
        bytes32 requestHash
    );

    function confirmMintRequest(bytes32 requestHash) external onlyCustodian {
        uint nonce;
        Request memory request;

        (nonce, request) = getNonceAndMintRequest(requestHash);

        mintRequests[nonce].status = RequestStatus.APPROVED;
        require(controller.mint(request.requester, request.amount), "mint failed");

        emit MintConfirmed(
            request.nonce,
            request.requester,
            request.amount,
            request.btcDepositAddress,
            request.btcTxid,
            request.timestamp,
            requestHash
        );
        
    }

    event MintRejected(
        uint indexed nonce,
        address indexed requester,
        uint amount,
        string btcDepositAddress,
        string btcTxid,
        uint timestamp,
        bytes32 requestHash
    );

    function rejectMintRequest(bytes32 requestHash) external onlyCustodian {
        uint nonce;
        Request memory request;

        (nonce, request) = getNonceAndMintRequest(requestHash);

        mintRequests[nonce].status = RequestStatus.REJECTED;

        emit MintRejected(
            request.nonce,
            request.requester,
            request.amount,
            request.btcDepositAddress,
            request.btcTxid,
            request.timestamp,
            requestHash
        );
    }

    event BurnConfirmed(
        uint indexed nonce,
        address indexed requester,
        uint amount,
        string btcDepositAddress,
        string btcTxid,
        uint timestamp,
        bytes32 inputRequestHash
    );

    function confirmBurnRequest(bytes32 requestHash, string btcTxid) external onlyCustodian {
        uint nonce;
        Request memory request;

        (nonce, request) = getNonceAndBurnRequest(requestHash);

        burnRequests[nonce].btcTxid = btcTxid;
        burnRequests[nonce].status = RequestStatus.APPROVED;
        burnRequestNonce[calcRequestHash(burnRequests[nonce])] = nonce;

        emit BurnConfirmed(
            request.nonce,
            request.requester,
            request.amount,
            request.btcDepositAddress,
            btcTxid,
            request.timestamp,
            requestHash
        );
    }

    event MintRequestCancel(uint indexed nonce, address indexed requester, bytes32 requestHash);

    function cancelMintRequest(bytes32 requestHash) external onlyMerchant {
        uint nonce;
        Request memory request;

        (nonce, request) = getNonceAndMintRequest(requestHash);

        require(msg.sender == request.requester, "cancel sender is different than pending request initiator");
        mintRequests[nonce].status = RequestStatus.CANCELED;

        emit MintRequestCancel(nonce, msg.sender, requestHash);
    }

    function getMintRequest(uint nonce)
        public
        view
        returns(
            uint requestNonce,
            address requester,
            uint amount,
            string btcDepositAddress,
            string btcTxid,
            uint timestamp,
            string status,
            bytes32 requestHash
        )
    {
        Request memory request = mintRequests[nonce];
        string memory statusString = getStatusString(request.status); 
        return (
            request.nonce,
            request.requester,
            request.amount,
            request.btcDepositAddress,
            request.btcTxid,
            request.timestamp,
            statusString,
            calcRequestHash(request)
        );
    }

    function getBurnRequest(uint nonce)
        public
        view
        returns(
            uint requestNonce,
            address requester,
            uint amount,
            string btcDepositAddress,
            string btcTxid,
            uint timestamp,
            string status,
            bytes32 requestHash
        )
    {
        Request storage request = burnRequests[nonce];
        string memory statusString = getStatusString(request.status); 
        return (
            request.nonce,
            request.requester,
            request.amount,
            request.btcDepositAddress,
            request.btcTxid,
            request.timestamp,
            statusString,
            calcRequestHash(request)
        );
    }

    function getMintRequestsLength() public view returns (uint length) {
        return mintRequests.length;
    }

    function getBurnRequestsLength() public view returns (uint length) {
        return burnRequests.length;
    }

    function compareStrings (string a, string b) public pure returns (bool) {
        return (keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b)));
    }

    function isEmptyString (string a) public pure returns (bool) {
        return (compareStrings(a, ""));
    }

    function getTimestamp() internal view returns (uint) {
        //timestamp is only used for data maintaining purpose, it is not relied on for critical logic
        return block.timestamp; // solhint-disable-line not-rely-on-time
        
    }

    function getNonceAndMintRequest(bytes32 requestHash) internal view returns (uint nonce, Request memory request) {
        require(requestHash != 0, "request hash is 0");
        nonce = mintRequestNonce[requestHash];
        request = mintRequests[nonce];
        validataeRequest(request, requestHash);
    }

    function getNonceAndBurnRequest(bytes32 requestHash) internal view returns (uint nonce, Request memory request) {
        require(requestHash != 0, "request hash is 0");
        nonce = burnRequestNonce[requestHash];
        request = burnRequests[nonce];
        validataeRequest(request, requestHash);
    }

    function validataeRequest(Request memory request, bytes32 requestHash) internal pure {
        require(request.status == RequestStatus.PENDING, "request is not pending");
        require(requestHash == calcRequestHash(request), "given request hash does not match a pending request");
    }

    function calcRequestHash(Request request) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            request.requester,
            request.amount,
            request.btcDepositAddress,
            request.btcTxid,
            request.nonce,
            request.timestamp
        ));
    }

    function getStatusString(RequestStatus status) internal pure returns (string) {
        if (status == RequestStatus.PENDING) {
            return "pending";
        } else if (status == RequestStatus.CANCELED) {
            return "canceled";
        } else if (status == RequestStatus.APPROVED) {
            return "approved";
        } else if (status == RequestStatus.REJECTED) {
            return "rejected";
        }
    }
}