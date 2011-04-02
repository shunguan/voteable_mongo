module Mongoid
  module Voteable
    extend ActiveSupport::Concern

    # How many points should be assigned for each up or down vote.
    # This hash should manipulated using voteable method
    VOTEABLE = {}

    included do
      include Mongoid::Document
      field :votes, :type => Mongoid::Voteable::Votes
      
      scope :voted_by, lambda { |voter|
        voter_id = voter.is_a?(BSON::ObjectId) ? voter : voter._id
        any_of({ 'votes.up' => voter_id }, { 'votes.down' => voter_id })
      }
      
      scope :up_voted_by, lambda { |voter|
        voter_id = voter.is_a?(BSON::ObjectId) ? voter : voter._id
        where( 'votes.up' => voter_id )
      }
      
      scope :down_voted_by, lambda { |voter|
        voter_id = voter.is_a?(BSON::ObjectId) ? voter : voter._id
        where( 'votes.down' => voter_id )
      }
      
      before_create do
        # Init votes so that counters and point have numeric values (0)
        self.votes = VOTES_DEFAULT_ATTRIBUTES
      end
      
      # Set vote point for each up (down) vote on an object of this class
      # 
      # @param [Hash] options a hash containings:
      # 
      # voteable self, :up => +1, :down => -3
      # voteable Post, :up => +2, :down => -1, :update_counters => false # skip counter update
      def self.voteable(klass = self, options = nil)
        VOTEABLE[self.name] ||= {}
        VOTEABLE[self.name][klass.name] ||= options
      end

      # Make a vote on an object of this class
      #
      # @param [Hash] options a hash containings:
      #   - :votee_id: the votee document id
      #   - :voter_id: the voter document id
      #   - :value: :up or :down
      #   - :revote: change from vote up to vote down
      #   - :unvote: unvote the vote value (:up or :down)
      def self.vote(options)
        options.symbolize_keys!
        value = options[:value].to_sym
        
        votee_id = options[:votee_id]
        voter_id = options[:voter_id]
        
        votee_id = BSON::ObjectId(votee_id) if votee_id.is_a?(String)
        voter_id = BSON::ObjectId(voter_id) if voter_id.is_a?(String)
        
        successed = true
        
        if voteable = VOTEABLE[name][name]
          if options[:revote]
            if value == :up
              positive_voter_ids = 'votes.up'
              negative_voter_ids = 'votes.down'
              positive_votes_count = 'votes.up_count'
              negative_votes_count = 'votes.down_count'
              point_delta = voteable[:up] - voteable[:down]
            else
              positive_voter_ids = 'votes.down'
              negative_voter_ids = 'votes.up'
              positive_votes_count = 'votes.down_count'
              negative_votes_count = 'votes.up_count'
              point_delta = -voteable[:up] + voteable[:down]
            end
          
            update_result = collection.update({ 
              # Validate voter_id did a vote with value for votee_id
              :_id => votee_id,
              positive_voter_ids => { '$ne' => voter_id },
              negative_voter_ids => voter_id
            }, {
              # then update
              '$pull' => { negative_voter_ids => voter_id },
              '$push' => { positive_voter_ids => voter_id },
              '$inc' => {
                positive_votes_count => +1,
                negative_votes_count => -1,
                'votes.point' => point_delta
              }
            }, {
              :safe => true
            })

          elsif options[:unvote]
            if value == :up
              positive_voter_ids = 'votes.up'
              negative_voter_ids = 'votes.down'
              positive_votes_count = 'votes.up_count'
            else
              positive_voter_ids = 'votes.down'
              negative_voter_ids = 'votes.up'
              positive_votes_count = 'votes.down_count'
            end
          
            # Check if voter_id did a vote with value for votee_id
            update_result = collection.update({ 
              # Validate voter_id did a vote with value for votee_id
              :_id => votee_id,
              negative_voter_ids => { '$ne' => voter_id },
              positive_voter_ids => voter_id
            }, {
              # then update
              '$pull' => { positive_voter_ids => voter_id },
              '$inc' => {
                positive_votes_count => -1,
                'votes.count' => -1,
                'votes.point' => -voteable[value]
              }
            }, {
              :safe => true
            })
          
          else # new vote
            if value.to_sym == :up
              positive_voter_ids = 'votes.up'
              positive_votes_count = 'votes.up_count'
            else
              positive_voter_ids = 'votes.down'
              positive_votes_count = 'votes.down_count'
            end

            update_result = collection.update({ 
              # Validate voter_id did not vote for votee_id yet
              :_id => votee_id,
              'votes.up' => { '$ne' => voter_id },
              'votes.down' => { '$ne' => voter_id }
            }, {
              # then update
              '$push' => { positive_voter_ids => voter_id },
              '$inc' => {  
                'votes.count' => +1,
                positive_votes_count => +1,
                'votes.point' => voteable[value] }
            }, {
              :safe => true
            })
          end

          successed = ( update_result['err'] == nil and 
            update_result['updatedExisting'] == true and
            update_result['n'] == 1 )
        end
        
        # Only update parent class if votee is updated successfully
        if successed
          votee ||= options[:votee] || find(options[:votee_id])
          Voteable::update_parent_votes(votee, options)
        end
        
        successed
      end
    end # include
    
    # Make a vote on this votee
    #
    # @param [Hash] options a hash containings:
    #   - :voter_id: the voter document id
    #   - :value: vote :up or vote :down
    #   - :revote: change from vote up to vote down
    #   - :unvote: unvote the vote value (:up or :down)
    def vote(options)
      options[:votee_id] = _id
      options[:votee] = self

      if options[:unvote]
        options[:value] ||= vote_value(options[:voter_id])
      else
        options[:revote] ||= vote_value(options[:voter_id]).present?
      end

      self.class.vote(options)
    end

    # Get a voted value on this votee
    #
    # @param [Mongoid Object, BSON::ObjectId] voter is Mongoid object or the id of the voter who made the vote
    def vote_value(voter)
      voter_id = voter.is_a?(BSON::ObjectId) ? voter : voter._id
      return :up if up_voter_ids.include?(voter_id)
      return :down if down_voter_ids.include?(voter_id)
    end

    # Array of up voter ids
    def up_voter_ids
      votes.try(:[], 'up') || []
    end

    # Array of down voter ids
    def down_voter_ids
      votes.try(:[], 'down') || []
    end

    # Get the number of up votes
    def up_votes_count
      votes.try(:[], 'up_count') || 0
    end
  
    # Get the number of down votes
    def down_votes_count
      votes.try(:[], 'down_count') || 0
    end
  
    # Get the number of votes
    def votes_count
      votes.try(:[], 'count') || 0
    end
  
    # Get the votes point
    def votes_point
      votes.try(:[], 'point') || 0
    end
    
    private
      def self.update_parent_votes(votee, options)
        value = options[:value].to_sym
        klass = votee.class
      
        VOTEABLE[klass.name].each do |class_name, voteable|
          # For other class in VOTEABLE options, if is parent of current class
          next unless relation_metadata = klass.relations[class_name.underscore]
          # If can find current votee foreign_key value for that class
          next unless foreign_key_value = votee.read_attribute(relation_metadata.foreign_key)
      
          inc_options = {}
        
          if options[:revote]
            if value == :up
              inc_options['votes.point'] = voteable[:up] - voteable[:down]
              unless voteable[:update_counters] == false
                inc_options['votes.up_count'] = +1
                inc_options['votes.down_count'] = -1
              end
            else
              inc_options['votes.point'] = -voteable[:up] + voteable[:down]
              unless voteable[:update_counters] == false
                inc_options['votes.up_count'] = -1
                inc_options['votes.down_count'] = +1
              end
            end
          elsif options[:unvote]
            inc_options['votes.point'] = -voteable[value]
            unless voteable[:update_counters] == false
              inc_options['votes.count'] = -1
              if value == :up
                inc_options['votes.up_count'] = -1
              else
                inc_options['votes.down_count'] = -1
              end
            end
          else # new vote
            inc_options['votes.point'] = voteable[value]
            unless voteable[:update_counters] == false
              inc_options['votes.count'] = +1
              if value == :up
                inc_options['votes.up_count'] = +1
              else
                inc_options['votes.down_count'] = +1
              end
            end
          end
                
          class_name.constantize.collection.update(
            { '_id' => foreign_key_value }, 
            { '$inc' => inc_options }
          )
        end
      end
    
  end
end
