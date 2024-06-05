pragma solidity >=0.7.0 <0.9.0;

contract Casino{
    // phase constant
    uint private constant RNC_PERIOD = 2 hours;
    uint private constant OPEN_PERIOD = 12 hours;
    uint private constant REVEAL_R_DEADLINE = 1 hours;
    uint private constant REPORT_PERIOD = 2 hours; // must be longer than CASINO_RESPOND_TIME, otherwise casino can cash out without announce result for bet
    uint private constant BET_VALUE = 0.01 ether;
    uint private constant CASINO_RESPOND_TIME = 1 hours; // casino must announce the bet within 1 hour after the betting.

    // casino address and the actual time for each phase
    address public casino;
    address public authorities = 0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2;
    uint public deployTime;
    uint public RNCTime;
    uint public openTime;
    uint public closeTime;
    uint public reveal_r_Time;
    uint public reportTime;
    bool public isCasinoOpened;

    // Modifier that make sure correct function called in correct phase
    event RNCPeriod(uint startingTime, uint endingTime);
    event BettingPeriod(uint startingTime, uint endingTime);
    event ReportPeriod(uint startingTime, uint endingTime);

    // The function has been called too early.
    // Try again at `time`.
    error TooEarly(uint time);
    // The function has been called too late.
    // It cannot be called after `time`.
    error TooLate(uint time);
    // The function has been called too early.
    // It cannot be called when casino have not opened, i.e. after announce Enc_r.
    error CasinoNotOpen();

    modifier onlyBefore(uint time) {
        if (block.timestamp >= time) revert TooLate(time);
        _;
    }
    modifier onlyAfter(uint time) {
        if (block.timestamp <= time) revert TooEarly(time);
        _;
    }
    modifier onlyOpened(){
        if (!isCasinoOpened) revert CasinoNotOpen();
        _;
    }

    // Assume the casino generate those pair of key using Goldwasser–Micali system.
    // This pair of key is just for demo purpose.
    // uint p = 13;
    // uint q = 17;
    // uint x = 7;
    // uint N = 221;
    uint256 public p;
    uint256 public q;
    uint256 public x;
    uint256 public N;

    constructor(uint256 _x, uint256 _N){
        x = _x;
        N = _N;
        casino = msg.sender;
        deployTime = block.timestamp;
        RNCTime = deployTime + RNC_PERIOD;
        isCasinoOpened = false;
        emit RNCPeriod(deployTime, RNCTime);
    }

    // RNC phase, player can encrypt their r_i by the gm encryption system.
    bytes32 verEnc_r = 0x0000000000000000000000000000000000000000000000000000000000000001; // the multiple of all enc(ri) until a time
    mapping(address => bytes32) private enced_ris; // player to their enc(ri)
    address[] public RNCcontributedPlayers; // list of contributed players that is not controlled by the authorities
    bytes32[] public authorities_enced_ris; // list of enc(ri) given by the authorities
    uint private t; // the number required by the authorities
    function contributeRNC(bytes32 enced_ri) external{
        require(!isCasinoOpened, "RNG finished");
        require(enced_ris[msg.sender]!=bytes32(0), "You have already contributed.");
        if(msg.sender != authorities){ // this player is not controlled by the authorities
            require(block.timestamp <= RNCTime, "The RNC time for player not controlled by authorities is over.");
            enced_ris[msg.sender] = enced_ri;
            RNCcontributedPlayers.push(msg.sender);
            t = calT();
        }
        else if (msg.sender == authorities){ // this player is controlled by the authorities
            if(block.timestamp > RNCTime){ // normal RNC time is over, only allow authorities add enc_ri if t is not enough
                require(authorities_enced_ris.length < t, "The authorities have already controlled t players.");
            }
            authorities_enced_ris.push(enced_ri);
            t = calT();
        }
        verEnc_r = bytes32(uint256(verEnc_r) * uint256(enced_ri));
    }
    function calT() private view returns(uint t){
        uint n = RNCcontributedPlayers.length + authorities_enced_ris.length;
        uint value;
        if (n % 2 == 0) value = n / 2;
        else value = n / 2 + 1;
        return value;
    }

    // the casino is able to decrypt r because they have sk=(p,q), they keep r secret
    bytes32 public enc_r; // the pulish enc_r used for the day
    bool private isEnc_rPublished; 
    uint private betLimit; // bet limit for requirement i
    function pulishEnc_r(bytes32 _enc_r) external payable onlyAfter(RNCTime) {
        require(msg.sender == casino, "Only casino can public Enc(r) and open casino.");
        require(msg.value >= 100 ether, "Must deposits a huge amount of money in the smart contract");
        require(!isEnc_rPublished, "Casino have already opened.");
        require(authorities_enced_ris.length >= t, "The authorities have not control at least t players yet.");
        enc_r = _enc_r;
        openTime = block.timestamp;
        closeTime = openTime + OPEN_PERIOD;
        reveal_r_Time = closeTime + REVEAL_R_DEADLINE;
        reportTime = reveal_r_Time + REPORT_PERIOD;
        isEnc_rPublished = true;
        isCasinoOpened = true;
        betLimit = (msg.value - 1 ether)/(0.01 ether); // -1 ether as 1 ether will be given to RNG players
        emit BettingPeriod(openTime, closeTime);
    }

    // after that the casino is opened and bettor can bet.

    // casino add deposit to allow more bets (for requirement i)
    function addDeposit() external payable onlyOpened() onlyAfter(openTime){
        require(msg.sender == casino, "Only casino can add deposit");
        require(msg.value > 0, "You must add deposit");
        betLimit += msg.value/0.01 ether;
    }

    // 1 ETH will evenly distributed to RNG players
    mapping (address => bool) public gotIncentivized;
    function getIncentive() public onlyOpened(){
        require(enced_ris[msg.sender]!=bytes32(0), "You didnt contributed to the RNC");
        require(!gotIncentivized[msg.sender], "You have already claim the incentivized.");
        uint reward = 1 ether;
        if(msg.sender != authorities){ // not controlled players get their own incentive
            reward /= (RNCcontributedPlayers.length + authorities_enced_ris.length);
            gotIncentivized[msg.sender] = true;
            (bool sent, bytes memory __) = payable(msg.sender).call{value: reward}("");
            require(sent, "fallback function exc fail");
        }
        else if (msg.sender == authorities){ // authorities will get the incentive for all its controlled players
            reward /= (RNCcontributedPlayers.length + authorities_enced_ris.length);
            reward *= authorities_enced_ris.length;
            gotIncentivized[msg.sender] = true;
            (bool sent, bytes memory __) = payable(msg.sender).call{value: reward}("");
            require(sent, "fallback function exc fail");
        }
    }

    // The betting phase, bettor call this function.
    uint private numBet;
    mapping(uint256 => address) public k_To_bettor; // the same k can only be used for one bettor, and cant reuse again.
    mapping(uint256 => uint) public betTime; // the betting time of this bet
    // betNotPaid is used for recording the bet that have not paid (for casino cash out withdrawl use)
    // it count for bet that is:
    // 1. Bet not yet announced result.
    // 2. Bet that is bettor won but not yet claimed.
    uint betNotPaid; 
    function bet(uint256 _k) external payable onlyOpened() onlyAfter(openTime) onlyBefore(closeTime){
        require(msg.value == BET_VALUE, "You must place a bet.");
        require(numBet < betLimit, "current betting number is no enought to ensure compensation.");
        require(k_To_bettor[_k]==address(0), "This value k is used, choose another one.");
        k_To_bettor[_k] = msg.sender;
        betTime[_k] = block.timestamp;
        betNotPaid++; // consider this bet have not paid in current moment
    }
 
    // This function will not be recorded on the blockchain, only use locally.
    // This part is not real implemented.
    // seed = _r + _k
    function rand(uint16 _r, uint _k) public pure returns(uint256 x){
        uint256 seed = uint256(_r) + _k;
        uint256 random = uint256(keccak256(abi.encodePacked(seed)));
        return random;
    }

    // This function is called by the casino to announce a player is won or not.
    mapping(uint256 => bool) public isThisKWin;
    mapping(uint256 => bool) public announced; // casino have announced this k value result
    function announceResult(uint _k, bool isXEven) public onlyOpened() onlyAfter(openTime){
        require(msg.sender == casino, "Only casino can announce bet result");
        require(!announced[_k], "The result of this bet is announced already");
        require(k_To_bettor[_k]!=address(0), "Bettor not exist");
        require(!isCasinoCashOuted, "You have already cash outed and cant announce result anymore");
        isThisKWin[_k] = isXEven;
        announced[_k] = true;
        if(!isXEven) betNotPaid--; // casino win, bet need to pay -1 as the casino no need to pay this bet
    }

    // This function is called by the bettor to know the result of a bet and claim this bet reward if any.
    // return true if win, false if lose
    mapping(uint => bool) public isProcessed;
    function claimResult(uint _k) external onlyOpened() onlyAfter(openTime) returns(bool win){
        require(!isProcessed[_k], "The bet have already processed.");
        require(k_To_bettor[_k]==msg.sender, "You are not the bettor of this k value");
        if (!announced[_k]){ // the casino have not process the bet yet
            if(block.timestamp > betTime[_k] + CASINO_RESPOND_TIME){ // the casino fails to respond the bet within time
                isProcessed[_k] = true;
                isThisKWin[_k] = true;
                announced[_k] = true;
                (bool sent, bytes memory __) = payable(msg.sender).call{value: 2*BET_VALUE}("");
                require(sent, "fallback function exc fail");
                betNotPaid--;
                return true;
            }
            else{
                require(false, "The casino have not announce you bet result but they still have time to do it.");
            }
        }
        else{ // the casino have processed the bet
            if(isThisKWin[_k]){ // this bet is won
                isProcessed[_k] = true;
                (bool sent, bytes memory __) = payable(msg.sender).call{value: 2*BET_VALUE}("");
                require(sent, "fallback function exc fail");
                betNotPaid--;
                return true;
            }
            else{ // this bet lose
                isProcessed[_k] = true;
                return false;
            }
        }
    }

    // this function is called by the casino to disclose r used for the day
    bool public isDisclosed;
    bool public cheatInR;
    uint16 public r;
    function discloseR(uint16 _r, uint256 _p, uint256 _q) public onlyOpened() onlyAfter(closeTime) onlyBefore(reveal_r_Time){
        require(msg.sender == casino, "Only casino can disclosed r and open casino.");
        require(!isDisclosed, "You have already disclosed r.");
        p = _p;
        r = _r;
        q = _q;
        isDisclosed = true;
        // secret key not match with public key
        if(p*q != N) cheatInR = true;
        // the r is not from all player r_i, that is enc_r1 * enc_r2 * ... * enc_rn
        if (enc_r != verEnc_r) cheatInR = true;
        // decryption not equal
        if (!testDecryption()) cheatInR = true;

        reveal_r_Time = block.timestamp;
        reportTime = reveal_r_Time+ REPORT_PERIOD;
        emit ReportPeriod(reveal_r_Time, reportTime);
    } 
    function testDecryption() private view returns(bool same){
        // this is a function to check whether Dec(Enc(r)) = r using sk=(p,q)
        // but I dont know how to implement the decryption system of GM :(
        return true;
    } 

    // this function can be called by anyone if the casino fails to disclose r before the deadline
    function noRDisclose() public onlyOpened() onlyAfter(reveal_r_Time){
        require(!isDisclosed, "The casino have already disclosed r.");
        require(!cheatInR, "Already know casino cheated in r value, you can call reportCheating() before deadline");
        cheatInR = true;
        reveal_r_Time = block.timestamp;
        reportTime = reveal_r_Time+ REPORT_PERIOD;
        emit ReportPeriod(reveal_r_Time, reportTime);
    }

    // for bettor to report casino cheating in a specify k
    // return true if report successful, false if not
    mapping(uint => bool) public isSuccessReport;
    function reportCheating(uint _k) external onlyOpened() onlyAfter(reveal_r_Time) onlyBefore(reportTime) returns(bool isSuccess){
        require(k_To_bettor[_k]==msg.sender, "You are not the bettor of this k value");
        require(isProcessed[_k], "You must call claimResult() first.");
        require(!isThisKWin[_k], "You didn't lose any money.");
        require(!isSuccessReport[_k], "You have already reported and compensated.");
        if(cheatInR){ // the casino cheated in disclosing not the valid r
            isSuccessReport[_k] = true;
            (bool sent, bytes memory __) = payable(msg.sender).call{value: 2*BET_VALUE}("");
            require(sent, "fallback function exc fail");
            return true;
        }
        // check whether different r is used in the bet
        x = rand(r, _k);
        if(x%2 == 0){ // x is indeed even but casino claim it is odd before
            isSuccessReport[_k] = true;
            (bool sent, bytes memory __) = payable(msg.sender).call{value: 2*BET_VALUE}("");
            require(sent, "fallback function exc fail");
            return true;
        }
        // no cheating for the casino
        return false;
    }

    // casino withdraw money from contract
    bool isCasinoCashOuted;
    function casinoWithdrawl() public onlyOpened() onlyAfter(reportTime){
        require(msg.sender == casino, "Only casino can withdraw its deposit");
        require(!isCasinoCashOuted, "You have already withdrawed");
        isCasinoCashOuted = true;
        // will not withdrawl all balance.
        (bool sent, bytes memory __) = payable(casino).call{value: address(this).balance - betNotPaid*2*BET_VALUE}("");
        require(sent, "fallback function exc fail");
    }  


}