pragma solidity ^0.4.4;

import 'zeppelin-solidity/contracts/math/SafeMath.sol';

contract DepositsManager {
  using SafeMath for uint;

  mapping(address => uint) public deposits;
  uint public jackpot;
  address public owner;

  event DepositMade(address who, uint amount);
  event DepositWithdrawn(address who, uint amount);
  event JackpotIncreased(uint amount);

  /// @dev The constructor
  function DepositsManager() public {
    owner = msg.sender;
  }
  
  /// @dev fallback to calling makeDeposit when ether is sent directly to contract.
  function() public payable {
    makeDeposit();
  }

  /// @dev Returns an account's deposit
  /// @param who The account's address.
  /// @return The account's deposit.
  function getDeposit(address who) constant public returns (uint) {
    return deposits[who];
  }

  /// @dev Allows a user to deposit eth.
  /// @return The user's updated deposit amount.
  function makeDeposit() public payable returns (uint) {
    deposits[msg.sender] = deposits[msg.sender].add(msg.value);
    DepositMade(msg.sender, msg.value);
    return deposits[msg.sender];
  }

  /// @dev Allows a user to withdraw eth from their deposit.
  /// @param amount How much eth to withdraw
  /// @return The user's updated deposit amount.
  function withdrawDeposit(uint amount) public returns (uint) {
    require(deposits[msg.sender] > amount);

    deposits[msg.sender] = deposits[msg.sender].sub(amount);
    msg.sender.transfer(amount);

    DepositWithdrawn(msg.sender, amount);
    return deposits[msg.sender];
  }

}