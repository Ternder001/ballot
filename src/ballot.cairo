use Voting::Candidate;
use starknet::ContractAddress;

#[starknet::interface]
pub trait IVoting<TContractState> {
    fn get_owner_address(self: @TContractState) -> ContractAddress;
    fn get_candidate_details(self: @TContractState, candidate_id: u32) -> Candidate;
    fn get_voting_winner(self: @TContractState) -> Candidate;
    fn get_current_leader(self: @TContractState) -> Candidate;
    fn get_proposal_description(self: @TContractState) -> ByteArray;
    fn list_all_candidates(self: @TContractState) -> Array<Candidate>;
    fn cast_vote(ref self: TContractState, candidate_id: u32);
    fn add_new_candidate(ref self: TContractState, candidate_address: ContractAddress, candidate_name: felt252);
    fn register_new_voter(ref self: TContractState, voter_address: ContractAddress);
    fn conclude_voting(ref self: TContractState);
    fn set_proposal_description(ref self: TContractState, proposal: ByteArray);
}

#[starknet::contract]
pub mod Voting {
    use core::starknet::event::EventEmitter;
    use starknet::{ContractAddress, get_caller_address};
    use super::IVoting;

    #[storage]
    struct Storage {
        proposal_description: ByteArray,
        owner_address: ContractAddress,
        next_candidate_id: u32,
        total_voters_count: u32,
        candidates_list: LegacyMap::<u32, Candidate>,
        registered_voters: LegacyMap::<ContractAddress, bool>,
        voter_status: LegacyMap::<ContractAddress, bool>,
        voting_ended: bool,
        winning_candidate: Candidate,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        NewCandidateAdded: CandidateAdded,
        NewVoterRegistered: VoterRegistered,
        VoteCast: Voted,
        VotingConcluded: VotingEnded,
    }

    #[derive(Drop, starknet::Event)]
    struct CandidateAdded {
        #[key]
        id: u32,
        address: ContractAddress,
        name: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct VoterRegistered {
        address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Voted {
        #[key]
        candidate_id: u32,
        voter: ContractAddress,
    }

    #[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
    pub struct Candidate {
        pub id: u32,
        pub name: felt252,
        pub address: ContractAddress,
        pub votes_count: u32,
    }

    #[derive(Drop, starknet::Event)]
    struct VotingEnded {
        #[key]
        winner_id: u32,
        winner_address: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner_address: ContractAddress) {
        self.owner_address.write(owner_address);
    }

    #[abi(embed_v0)]
    impl VotingImpl of IVoting<ContractState> {
        fn get_owner_address(self: @ContractState) -> ContractAddress {
            self.owner_address.read()
        }

        fn get_proposal_description(self: @ContractState) -> ByteArray {
            self.proposal_description.read()
        }

        fn get_candidate_details(self: @ContractState, candidate_id: u32) -> Candidate {
            InternalImpl::_validate_candidate(self, candidate_id);
            self.candidates_list.read(candidate_id)
        }

        fn list_all_candidates(self: @ContractState) -> Array<Candidate> {
            let mut index = 0;
            let mut candidates = ArrayTrait::new();
            while index < self.next_candidate_id.read() {
                candidates.append(self.candidates_list.read(index));
                index += 1;
            };
            candidates
        }

        fn get_voting_winner(self: @ContractState) -> Candidate {
            assert(self.voting_ended.read(), 'VOTING_NOT_ENDED');
            self.winning_candidate.read()
        }

        fn cast_vote(ref self: ContractState, candidate_id: u32) {
            self._validate_registered_voter();
            self._validate_vote_status();
            self._validate_voting_status();
            let candidate = self.candidates_list.read(candidate_id);
            self
                .candidates_list
                .write(candidate_id, Candidate { votes_count: candidate.votes_count + 1, ..candidate });

            self.emit(Voted { candidate_id, voter: get_caller_address() });
        }

        fn add_new_candidate(ref self: ContractState, candidate_address: ContractAddress, candidate_name: felt252) {
            self._validate_owner();
            let candidate_id = self.next_candidate_id.read();
            self.next_candidate_id.write(candidate_id + 1);
            self
                .candidates_list
                .write(
                    candidate_id,
                    Candidate { id: candidate_id, name: candidate_name, address: candidate_address, votes_count: 0, }
                );
            self.emit(CandidateAdded { id: candidate_id, address: candidate_address, name: candidate_name, });
        }

        fn register_new_voter(ref self: ContractState, voter_address: ContractAddress) {
            self._validate_owner();
            self.total_voters_count.write(self.total_voters_count.read() + 1);
            self.registered_voters.write(voter_address, true);
            self.emit(VoterRegistered { address: voter_address });
        }

        fn set_proposal_description(ref self: ContractState, proposal: ByteArray) {
            self._validate_owner();
            self.proposal_description.write(proposal);
        }

        fn get_current_leader(self: @ContractState) -> Candidate {
            let mut index = 1;
            let mut leader = self.candidates_list.read(0);
            while index < self.next_candidate_id.read() {
                let candidate = self.candidates_list.read(index);
                if candidate.votes_count > leader.votes_count {
                    leader = candidate;
                }
                index += 1;
            };
            leader
        }

        fn conclude_voting(ref self: ContractState) {
            self._validate_owner();
            let winner = self.get_current_leader();
            self.voting_ended.write(true);
            self.winning_candidate.write(winner);

            self.emit(VotingEnded { winner_id: winner.id, winner_address: winner.address });
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _validate_owner(self: @ContractState) {
            let caller = get_caller_address();
            assert(self.owner_address.read() == caller, 'NOT_OWNER');
        }

        fn _validate_registered_voter(self: @ContractState) {
            let caller = get_caller_address();
            assert(self.registered_voters.read(caller), 'NOT_REGISTERED_VOTER');
        }

        fn _validate_candidate(self: @ContractState, candidate_id: u32) {
            assert(candidate_id <= self.next_candidate_id.read(), 'INVALID_CANDIDATE');
        }

        fn _validate_vote_status(self: @ContractState) {
            let caller = get_caller_address();
            assert(!self.voter_status.read(caller), 'ALREADY_VOTED');
        }

        fn _validate_voting_status(self: @ContractState) {
            assert(!self.voting_ended.read(), 'VOTING_ALREADY_ENDED');
        }
    }
}

