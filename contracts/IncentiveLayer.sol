pragma solidity ^0.4.4;

import './DepositsManager.sol';
import './JackpotManager.sol';

contract IncentiveLayer is JackpotManager, DepositsManager {

	uint private numTasks = 0;
	uint private forcedErrorThreshold = 42;

 	event DepositBonded(uint taskID, address account, uint amount);
 	event DepositUnbonded(uint taskID, address account, uint amount);
 	event BondedDepositMovedToJackpot(uint taskID, address account, uint amount);
	event TaskCreated(uint taskID, uint minDeposit, uint blockNumber, uint reward);
	event SolverSelected(uint indexed taskID, address solver, bytes32 taskData, uint minDeposit, bytes32 randomBitsHash);
	event SolutionsCommitted(uint taskID, uint minDeposit, bytes32 taskData, address solver);
	event SolutionRevealed(uint taskID, uint randomBits);
	event TaskStateChange(uint taskID, uint state);
	event VerificationCommitted(address verifier, uint jackpotID, uint solutionID, uint index);

	enum State { TaskInitialized, SolverSelected, SolutionComitted, ChallengesAccepted, IntentsRevealed, SolutionRevealed, TaskFinalized, TaskTimeout }

	struct Task {
		address owner;
		address selectedSolver;
		uint minDeposit;
		uint reward;
		bytes32 taskData;
		mapping(address => bytes32) challenges;
		State state;
		bytes32 blockhash;
		bytes32 randomBitsHash;
		uint numBlocks;
		uint taskCreationBlockNumber;
    mapping(address => uint) bondedDeposits;
		uint randomBits;
		uint finalityCode; //0 => not finalized, 1 => finalized, 2 => forced error occurred
		uint jackpotID;
		uint initialReward;
	}

	struct Solution {
		bytes32 solutionHash0;
		bytes32 solutionHash1;
		bool solution0Correct;
		address[] solution0Challengers;
		address[] solution1Challengers;
		uint currentChallenger;
		bool solverConvicted;
	}

	mapping(uint => Task) private tasks;
	mapping(uint => Solution) private solutions;

	uint8[8] private timeoutWeights = [1, 20, 30, 35, 40, 45, 50, 55];//one timeout per state in the FSM

	/// @dev Private method to check if the denoted amount of blocks have been mined (time has passed).
	/// @param taskID The task id.
	/// @return boolean
	function stateChangeTimeoutReached(uint taskID) private view returns (bool) {
		Task storage t = tasks[taskID];
		return block.number.sub(t.taskCreationBlockNumber) >= timeoutWeights[uint(t.state)-1];
	}

	/// @dev Locks up part of the a user's deposit into a task.
	/// @param taskID The task id.
	/// @param account The user's address.
	/// @param amount The amount of deposit to lock up. 
	/// @return The user's deposit bonded for the task.
	function bondDeposit(uint taskID, address account, uint amount) private returns (uint) { 
	  Task storage task = tasks[taskID];
	  require(deposits[msg.sender] >= amount);
	  deposits[account] = deposits[account].sub(amount);
	  task.bondedDeposits[account] = task.bondedDeposits[account].add(amount);
	  DepositBonded(taskID, account, amount);
	  return task.bondedDeposits[account];
	}

	/// @dev Unlocks a user's bonded deposits from a task.
	/// @param taskID The task id.
	/// @return The user's deposit which was unbonded from the task.
	function unbondDeposit(uint taskID) public returns (uint) {
	  Task storage task = tasks[taskID];
	  require(task.state == State.TaskFinalized || task.state == State.TaskTimeout);
	  uint bondedDeposit = task.bondedDeposits[msg.sender];
	  delete task.bondedDeposits[msg.sender];
	  deposits[msg.sender] = deposits[msg.sender].add(bondedDeposit);
	  DepositUnbonded(taskID, msg.sender, bondedDeposit);
	  
	  return bondedDeposit;
	}

	/// @dev Punishes a user by moving their bonded deposits for a task into the jackpot.
	/// @param taskID The task id.
	/// @param account The user's address.
	/// @return The updated jackpot amount.
	function moveBondedDepositToJackpot(uint taskID, address account) private returns (uint) { 
	  Task storage task = tasks[taskID];
	  uint bondedDeposit = task.bondedDeposits[account];
	  delete task.bondedDeposits[account];
	  jackpot = jackpot.add(bondedDeposit);
	  BondedDepositMovedToJackpot(taskID, account, bondedDeposit);
	  
	  return bondedDeposit;
	}

	/// @dev returns The user's bonded deposits for a task.
	/// @param taskID The task id.
	/// @param account The user's address.
	/// @return The user's bonded deposits for a task.
	function getBondedDeposit(uint taskID, address account) constant public returns (uint) {
	  return tasks[taskID].bondedDeposits[account];
	}

	/// @dev taskGiver creates tasks to be solved.
	/// @param minDeposit The minimum deposit required for engaging with a task as a solver or verifier.
	/// @param taskData Tbd could be hash of the wasm file on a filesystem.
	/// @param numBlocks The number of blocks to adjust for task difficulty.
	/// @return – boolean
	function createTask(uint minDeposit, bytes32 taskData, uint numBlocks) public payable returns (bool) {
		require(deposits[msg.sender] >= minDeposit);
		require(msg.value > 0);
		Task storage t = tasks[numTasks];
		t.owner = msg.sender;
		t.minDeposit = minDeposit;
		t.reward = msg.value;
		t.taskData = taskData;
		t.taskCreationBlockNumber = block.number;
		t.numBlocks = numBlocks;
		t.initialReward = t.reward;
		bondDeposit(numTasks, msg.sender, minDeposit);
		log0(keccak256(msg.sender));//possible bug if log is after event
		TaskCreated(numTasks, minDeposit, numBlocks, t.reward);
		numTasks.add(1);
		return true;
	}

		/// @dev changes A tasks state.
		/// @param taskID The task id.
		/// @param newState The new state.
		/// @return boolean
	function changeTaskState(uint taskID, uint newState) public returns (bool) {
		Task storage t = tasks[taskID];
		require(t.owner == msg.sender);
		require(stateChangeTimeoutReached(taskID));
		t.state = State(newState);
		TaskStateChange(taskID, newState);
		return true;
	}

	/// @dev solver registers for tasks, if first to register than automatically selected solver
	//  0 -> 1
	/// @param taskID The task id.
	/// @param randomBitsHash Hash of random bits to commit to task
	/// @return – boolean
	function registerForTask(uint taskID, bytes32 randomBitsHash) public returns(bool) {
		Task storage t = tasks[taskID];
		
		require(!(t.owner == 0x0));
		require(t.state == State.TaskInitialized);
		require(t.selectedSolver == 0x0);
    
    bondDeposit(taskID, msg.sender, t.minDeposit);
		t.selectedSolver = msg.sender;
		t.randomBitsHash = randomBitsHash;
		t.blockhash = block.blockhash(block.number.add(1));
		t.state = State.SolverSelected;

		SolverSelected(taskID, msg.sender, t.taskData, t.minDeposit, t.randomBitsHash);	
    return true;
	}

	/// @dev Selected solver submits a solution to the exchange
	// 1->2
	/// @param taskID The task id.
	/// @param solutionHash0 The hash of the solution (could be true or false solution)
	/// @param solutionHash1 The hash of the solution (could be true or false solution)
	/// @return boolean
	function commitSolution(uint taskID, bytes32 solutionHash0, bytes32 solutionHash1) public returns (bool) {
		Task storage t = tasks[taskID];
		require(t.selectedSolver == msg.sender);
		require(t.state == State.SolverSelected);
		require(block.number < t.taskCreationBlockNumber.add(t.numBlocks));
		Solution storage s = solutions[taskID];
		s.solutionHash0 = solutionHash0;
		s.solutionHash1 = solutionHash1;
		s.solverConvicted = false;
		t.state = State.SolutionComitted;
		SolutionsCommitted(taskID, t.minDeposit, t.taskData, msg.sender);
		return true;
	}

	function taskGiverTimeout(uint taskID) public {
		Task storage t = tasks[taskID];
		require(msg.sender == t.owner);
		Solution storage s = solutions[taskID];
		require(s.solutionHash0 == 0x0 && s.solutionHash1 == 0x0);
		require(block.number > t.taskCreationBlockNumber.add(t.numBlocks));
		moveBondedDepositToJackpot(taskID, t.selectedSolver);
		t.state = State.TaskTimeout;
	}

	/// @dev Verifier submits a challenge to the solution provided for a task
	// verifiers can call this until task giver changes state or timeout
	/// @param taskID The task id.
	/// @param intentHash Submit hash of even or odd number to designate which solution is correct/incorrect.
	/// @return – boolean
	function commitChallenge(uint taskID, bytes32 intentHash) public returns (bool) {
		Task storage t = tasks[taskID];
		require(t.state == State.SolutionComitted);

		bondDeposit(taskID, msg.sender, t.minDeposit);
		t.challenges[msg.sender] = intentHash;
		return true;
	}

	/// @dev Verifiers can call this until task giver changes state or timeout
	/// @param taskID The task id.
	/// @param intent Submit 0 to challenge solution0, 1 to challenge solution1, anything else challenges both
	/// @return boolean
	function revealIntent(uint taskID, uint intent) public returns (bool) {
		require(tasks[taskID].challenges[msg.sender] == keccak256(intent));
		require(tasks[taskID].state == State.ChallengesAccepted);
		uint solution = 0;
		uint position = 0;
		if (intent == 0) {//Intent determines which solution the verifier is betting is deemed incorrect
			position = solutions[taskID].solution0Challengers.length;
			solutions[taskID].solution0Challengers.push(msg.sender);
		} else if (intent == 1) {
			position = solutions[taskID].solution1Challengers.length;
			solutions[taskID].solution1Challengers.push(msg.sender);
			solution = 1;
		}
		delete tasks[taskID].challenges[msg.sender];
		VerificationCommitted(msg.sender, tasks[taskID].jackpotID, solution, position);
		return true;
	}

	/// @dev Solver reveals which solution they say is the correct one
	// 4->5
	/// @param taskID The task id.
	/// @param solution0Correct Determines if solution0Hash is the correct solution
	/// @param originalRandomBits Original random bits for sake of commitment.
	/// @return boolean
	function revealSolution(uint taskID, bool solution0Correct, uint originalRandomBits) public {
		Task storage t = tasks[taskID];
		require(t.randomBitsHash == keccak256(originalRandomBits));
		require(t.state == State.IntentsRevealed);
		require(t.selectedSolver == msg.sender);
		solutions[taskID].solution0Correct = solution0Correct;
		t.state = State.SolutionRevealed;
		t.randomBits = originalRandomBits;
		if (isForcedError(originalRandomBits)) { //this if statement will make this function tricky to test
			rewardJackpot(taskID);
			t.finalityCode = 2;
			t.state = State.TaskFinalized;
		} else {
			SolutionRevealed(taskID, originalRandomBits);
		}
	}

	function isForcedError(uint randomBits) internal view returns (bool) {
		return (uint(keccak256(randomBits, block.blockhash(block.number))) < forcedErrorThreshold);
	}

	function rewardJackpot(uint taskID) internal {
		Task storage t = tasks[taskID];
		Solution storage s = solutions[taskID];
		t.jackpotID = setJackpotReceivers(s.solution0Challengers, s.solution1Challengers);
		t.owner.transfer(t.reward);//send reward back to task giver as it was never used
	}

	//verifier should be responsible for calling this first
	function runVerificationGame(uint taskID) public {
		Task storage t = tasks[taskID];
		require(t.state == State.SolutionRevealed);
		Solution storage s = solutions[taskID];
		if (s.solution0Correct) {
			s.solverConvicted = verificationGame(t.selectedSolver, s.solution0Challengers[s.currentChallenger], t.taskData, s.solutionHash0);
		} else {
			s.solverConvicted = verificationGame(t.selectedSolver, s.solution1Challengers[s.currentChallenger], t.taskData, s.solutionHash1);
		}
		s.currentChallenger = s.currentChallenger + 1;
	}

	function verificationGame(address solver, address challenger, bytes32 taskData, bytes32 solutionHash) internal returns (bool) {
		solver;
		challenger;
		taskData;
		solutionHash;
		// noop
		return false;
	}

	function finalizeTask(uint taskID) public {
		Task storage t = tasks[taskID];
		Solution storage s = solutions[taskID];
		require(t.owner == msg.sender);
		require(s.currentChallenger >= s.solution0Challengers.length || s.currentChallenger >= s.solution1Challengers.length);
		t.state = State.TaskFinalized;
		t.finalityCode = 1;//Task has been completed
		distributeReward(t);
	}

	function getTaskFinality(uint taskID) public view returns (uint) {
		return tasks[taskID].finalityCode;
	}

	function distributeReward(Task t) internal {
		t.selectedSolver.transfer(t.reward);
	}

}