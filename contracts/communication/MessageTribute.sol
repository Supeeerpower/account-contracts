pragma solidity ^0.4.17;

import "../token/MiniMeToken.sol";
import "../common/Controlled.sol";


/**
 * @title MessageTribute
 * @author Richard Ramos (Status Research & Development GmbH) 
 * @dev Inspired by one of Satoshi Nakamoto’s original suggested use cases for Bitcoin, 
        we will be introducing an economics-based anti-spam filter, in our case for 
        receiving messages and “cold” contact requests from users.
        SNT is deposited, and transferred from stakeholders to recipients upon receiving 
        a reply from the recipient.
 */
contract MessageTribute is Controlled {

    event AudienceRequested(address indexed from, address indexed to);
    event AudienceCancelled(address indexed from, address indexed to);
    event AudienceTimeOut(address indexed from, address indexed to);
    event AudienceGranted(address indexed from, address indexed to, bool approve);

    struct Audience {
        uint256 blockNum;
        uint256 timestamp;
        Fee fee;
        bytes32 hashedSecret;
    }
    
    struct Fee {
        uint256 amount;
        bool permanent;
    }

    mapping(address => mapping(address => Audience)) audienceRequested;
    mapping(address => mapping(address => Fee)) public feeCatalog;
    mapping(address => mapping(address => uint)) lastAudienceDeniedTimestamp;
    mapping(bytes32 => uint256) private friendIndex;
    mapping(address => uint256) public balances;
    address[] private friends; 
    
    MiniMeToken public snt;
    
     /**
     * @notice Contructor of MessageTribute
     * @param _snt Address of Status Network Token (or any ERC20 compatible token)
     **/
    function MessageTribute(MiniMeToken _snt) public {
        snt = _snt;
    }

    /**
     * @notice Register friends addresses that won't require to pay any tribute
     * @param _friends Array of addresses to register
     */
    function addFriends(address[] _friends) public {
        uint256 len = _friends.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 frHash = keccak256(_friends[i], msg.sender);
            if (friendIndex[frHash] == 0)
                friendIndex[frHash] = friends.push(_friends[i]);
        }
    }
    
    /**
     * @notice Remove friends addresses from contract
     * @param _friends Array of addresses to remove
     */
    function removeFriends(address[] _friends) public {
        uint256 len = _friends.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 frHash = keccak256(_friends[i], msg.sender);
            require(friendIndex[frHash] > 0);
            uint index = friendIndex[frHash] - 1;
            delete friendIndex[frHash];
            address replacer = friends[friends.length - 1];
            friends[index] = replacer;
            friendIndex[keccak256(replacer, msg.sender)] = index;
            friends.length--;
        }
    }

    /**
     * @notice Determines if `accountToCheck` is registered as a friend of `sourceAccount`
     * @param _sourceAccount Address that has friends registered in the contract
     * @param _accountToCheck Address to verify if it is friend of `accountToCheck`
     * @return accounts are friends or not
     */
    function areFriends(address _sourceAccount, address _accountToCheck) public view returns(bool) {
        return friendIndex[keccak256(_accountToCheck, _sourceAccount)] > 0;
    }
    
    /**
     * @notice Set tribute for accounts or everyone
     * @param _to Address to set the tribute. If address(0), applies to everyone
     * @param _amount Required tribute amount (using token from constructor)
     * @param _isPermanent Tribute applies for all communications on only for the first
     */
    function setRequiredTribute(address _to, uint _amount, bool _isPermanent) public {
        require(friendIndex[keccak256(msg.sender, _to)] == 0);
        feeCatalog[msg.sender][_to] = Fee(_amount, _isPermanent);
    }
    
    /**
     * @notice Obtain amount of tokens required from `msg.sender` to contact `_from`
     * @return fee amount of tokens
     */
    function getRequiredFee(address _from) public view 
        returns (uint256 fee) 
    {
        Fee memory f = getFee(_from);
        fee = f.amount;
    }
    
    /**
     * @notice Deposit `_value` in the contract to be used to pay tributes
     * @param _value Amount to deposit
     */
    function deposit(uint256 _value) public {
        require(_value > 0);
        balances[msg.sender] += _value;
        require(snt.transferFrom(msg.sender, address(this), _value));
    }

    /**
     * @notice Return balance of tokens for `msg.sender` available for tributes or withdrawal
     * @return amount of tokens stored in contract
     */
    function balance() public view returns (uint256) {
        return balances[msg.sender];
    }

    /**
     * @notice Withdraw `_value` tokens from contract
     * @param _value Amount of tokens to withdraw
     */
    function withdraw(uint256 _value) public {
        require(balances[msg.sender] > 0);
        require(_value <= balances[msg.sender]);
        balances[msg.sender] -= _value;
        require(snt.transfer(msg.sender, _value)); 
    }

    /**
     * @notice Send a chat request to `_from`, with a captcha that must be solved
     * @param _from Account to whom `msg.sender` requests a chat
     * @param _hashedSecret Captcha that `_from` must solve. It's a keccak256 of `_from`, 
     *                     `msg.sender` and the captcha value shown to `_from`
     */
    function requestAudience(address _from, bytes32 _hashedSecret)
        public 
    {
        Fee memory f = getFee(_from);
        require(f.amount <= balances[msg.sender]);
        require(audienceRequested[_from][msg.sender].blockNum == 0);
        require(lastAudienceDeniedTimestamp[_from][msg.sender] + 3 days <= now);

        emit AudienceRequested(_from, msg.sender);
        audienceRequested[_from][msg.sender] = Audience(block.number, now, f, _hashedSecret);

        balances[msg.sender] -= f.amount;
    }

    /**
     * @notice Determine if there's a pending chat request between `_from` and `_to`
     * @param _from Account to whom `_to` had requested a chat
     * @param _to Account which requested a chat to `_from`
     */
    function hasPendingAudience(address _from, address _to) public view returns (bool) {
        return audienceRequested[_from][_to].blockNum > 0;
    }

    /**
     * @notice Can be called after 3 days if no response from `_from` is received
     * @param _from Account to whom `_to` had requested a chat
     * @param _to Account which requested a chat to `_from`
     */
    function timeOut(address _from, address _to) public {
        require(audienceRequested[_from][_to].blockNum > 0);
        require(audienceRequested[_from][_to].timestamp + 3 days <= now);
        emit AudienceTimeOut(_from, _to);
        balances[_to] += audienceRequested[_from][_to].fee.amount;
        delete audienceRequested[_from][_to];
    }

    /**
     * @notice Cancel chat request
     * @param _from Account to whom `msg.sender` had requested a chat previously
     */
    function cancelAudienceRequest(address _from) public {
        require(audienceRequested[_from][msg.sender].blockNum > 0);
        require(audienceRequested[_from][msg.sender].timestamp + 2 hours <= now);
        emit AudienceCancelled(_from, msg.sender);
        balances[msg.sender] += audienceRequested[_from][msg.sender].fee.amount;
        delete audienceRequested[_from][msg.sender];
    }

    /**
     * @notice Approve/Deny chat request to `_to`
     * @param _approve Approve or deny request
     * @param _waive Refund deposit or not
     * @param _secret Captcha solution
     */
    function grantAudience(address _to, bool _approve, bool _waive, bytes32 _secret) public {
        Audience storage aud = audienceRequested[msg.sender][_to];

        require(aud.blockNum > 0);
        require(aud.hashedSecret == keccak256(msg.sender, _to, _secret));
       
        emit AudienceGranted(msg.sender, _to, _approve);

        if(!_approve)
            lastAudienceDeniedTimestamp[msg.sender][_to] = block.timestamp;

        uint256 amount = aud.fee.amount;

        delete audienceRequested[msg.sender][_to];

        clearFee(msg.sender, _to);

        if (!_waive) {
            if (_approve) {
                require(snt.transfer(msg.sender, amount));
            } else {
                balances[_to] += amount;
            }
        } else {
            balances[_to] += amount;
        }
    }

    /**
     * @notice Determine if msg.sender ha enough funds to chat with `_to`
     * @param _to Account `msg.sender` wishes to talk to
     * @return Has enough funds or not
     */
    function hasEnoughFundsToTalk(address _to)
        public
        view 
        returns(bool)
    {
        return getFee(_to).amount <= balances[msg.sender];
    }

    /**
     * @notice Obtain required fee to talk with `_from`
     * @param _from Account `msg.sender` wishes to talk to
     * @return Fee
     */
    function getFee(address _from) internal view
        returns (Fee) 
    {
        Fee memory specificFee = feeCatalog[_from][msg.sender];

        if (friendIndex[keccak256(msg.sender, _from)] > 0)
            return Fee(0, false);

        Fee memory generalFee = feeCatalog[_from][address(0)];
        return specificFee.amount > 0 ? specificFee : generalFee;
    }

    /**
     * @notice Remove any tribute configuration between `_from` and `_to`
     * @param _from Owner of the configuration
     * @param _to Account that paid tributes (won't after this function is executed)
     */
    function clearFee(address _from, address _to) private {
        if (!feeCatalog[_from][_to].permanent) {
            feeCatalog[_from][_to].amount = 0;
            feeCatalog[_from][_to].permanent = false;
        }
    }
}