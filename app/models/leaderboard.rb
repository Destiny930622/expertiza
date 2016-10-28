# Currently this is a repository for a lot of static class methods.
# Many of the methods were moved to leaderboard_helper.rb and more
# probably should be moved.
class Leaderboard < ActiveRecord::Base
  # This module is not really required, but can be helpful when
  # using the script/console and needing to print hash structures.
  require 'pp'
  # This method gets all the assignments associated with a courses
  # in an array. A course_id of 0 will get assignments not affiliated
  # with a specific course.

  ### This methodreturns unaffiliiated assignments - assignments not affiliated to any course
  def self.get_independant_assignments(user_id)
    assignment_ids = AssignmentParticipant.where(user_id: user_id).pluck(:parent_id)
    no_course_assignments = Assignment.where(id: assignment_ids, course_id: nil)
  end

  def self.get_assignments_in_courses(course_array)
    assignment_list = Assignment.where(course_id: course_array)
  end

  # This method gets all tuples in the Participants table associated
  # hierarchy (qtype => course => user => score)

  def self.get_participant_entries_in_courses(course_array, user_id)
    assignment_list = []
    assignment_list = get_assignments_in_courses(course_array)
    independant_assignments = get_independant_assignments(user_id)
    assignment_list.concat(independant_assignments)

    questionnaire_hash = get_participants_score(assignment_list)
  end

  # This method gets all tuples in the Participants table associated
  # hierarchy (qtype => course => user => score).
  def self.get_participant_entries_in_assignment(assignment_id)
    assignment_list = []
    assignment_list << Assignment.find(assignment_id)
    questionnaire_hash = getParticipantEntriesInAssignmentList(assignment_list)
  end

  # This method returns the participants score grouped by course, grouped by questionnaire type.
  # End result is a hash (qType => (course => (user => score)))
  def self.get_participants_score(assignment_list)
    qTypeHash = {}
    questionnaire_response_type_hash = {"ReviewResponseMap" => "ReviewQuestionnaire",
                                        "MetareviewResponseMap" => "MetareviewQuestionnaire",
                                        "FeedbackResponseMap" => "AuthorFeedbackQuestionnaire",
                                        "TeammateReviewResponseMap" => "TeammateReviewQuestionnaire",
                                        "BookmarkRatingResponseMap" => "BookmarkRatingQuestionnaire"}

    # Get all participants of the assignment list
    participant_list = AssignmentParticipant.where(parent_id: assignment_list.pluck(:id)).uniq

    # Get all teams participated in the given assignment list.
    team_list = Team.where("parent_id IN (?) AND type = ?", assignment_list.pluck(:id), 'AssignmentTeam').uniq

    # Get mapping of participant and team with corresponding assignment.
    # "participant" => {participantId => {"self" => <ParticipantRecord>, "assignment" => <AssignmentRecord>}}
    # "team" => {teamId => <AssignmentRecord>}
    assignment_map = get_assignment_mapping(assignment_list, participant_list, team_list)

    # Aggregate total reviewee list
    reviewee_list = []
    reviewee_list = participant_list.pluck(:id)
    reviewee_list.concat(team_list.pluck(:id)).uniq!

    # Get scores from ScoreCache for computed reviewee list.
    scores = ScoreCache.where("reviewee_id IN (?) and object_type IN (?)", reviewee_list, questionnaire_response_type_hash.keys)

    for scoreEntry in scores
      reviewee_user_id_list = []
      if assignment_map["team"].key?(scoreEntry.reviewee_id)
        # Reviewee is a team. Actual Reviewee will be users of the team.
        team_user_ids = TeamsUser.where(team_id: scoreEntry.reviewee_id).pluck(:user_id)
        reviewee_user_id_list.concat(team_user_ids)
        courseId = assignment_map["team"][scoreEntry.reviewee_id].try(:course_id).to_i
      else
        # Reviewee is an individual participant.
        reviewee_user_id_list << assignment_map["participant"][scoreEntry.reviewee_id]["self"].try(:user_id)
        courseId = assignment_map["participant"][scoreEntry.reviewee_id]["assignment"].try(:course_id).to_i
      end

      questionnaireType = questionnaire_response_type_hash[scoreEntry.object_type]

      add_score_to_result_ant_hash(qTypeHash, questionnaireType, courseId, reviewee_user_id_list, scoreEntry.score)
    end

    qTypeHash
  end

  # This method adds score to all the revieweeUser in qTypeHash.
  # Later, qTypeHash will contain the final computer leaderboard.
  def self.add_score_to_result_ant_hash(qTypeHash, questionnaireType, courseId, revieweeUserIdList, scoreEntryScore)
    if revieweeUserIdList
      # Loop over all the revieweeUserId.
      for revieweeUserId in revieweeUserIdList
        if qTypeHash.fetch(questionnaireType, {}).fetch(courseId, {}).fetch(revieweeUserId, nil).nil?
          userHash = {}
          userHash[revieweeUserId] = [scoreEntryScore, 1]

          if qTypeHash.fetch(questionnaireType, {}).fetch(courseId, nil).nil?
            if qTypeHash.fetch(questionnaireType, nil).nil?
              courseHash = {}
              courseHash[courseId] = userHash

              qTypeHash[questionnaireType] = courseHash
            end

            qTypeHash[questionnaireType][courseId] = userHash
          end

          qTypeHash[questionnaireType][courseId][revieweeUserId] = [scoreEntryScore, 1]
        else
          # RevieweeUserId exist in qTypeHash. Update score.
          current_user_score = qTypeHash[questionnaireType][courseId][revieweeUserId]
          current_total_score = current_user_score[0] * current_user_score[1]
          current_user_score[1] += 1
          current_user_score[0] = (current_total_score + scoreEntryScore) / current_user_score[1]
        end
      end
    end
  end

  # This method creates a mapping of participant and team with corresponding assignment.
  # "participant" => {participantId => {"self" => <ParticipantRecord>, "assignment" => <AssignmentRecord>}}
  # "team" => {teamId => <AssignmentRecord>}
  def self.get_assignment_mapping(assignment_list, participant_list, team_list)
    result_hash = {"participant" => {}, "team" => {}}
    assignment_hash = {}
    # Hash all the assignments for later fetching them by assignment.id
    for assignment in assignment_list
      assignment_hash[assignment.id] = assignment
    end
    # Loop over all the participants to get corresponding assignment by parent_id
    for participant in participant_list
      result_hash["participant"][participant.id] = {}
      result_hash["participant"][participant.id]["self"] = participant
      result_hash["participant"][participant.id]["assignment"] = assignment_hash[participant.parent_id]
    end
    # Loop over all the teams to get corresponding assignment by parent_id
    for team in team_list
      result_hash["team"][team.id] = assignment_hash[team.parent_id]
    end

    result_hash
  end

  # This method does a destructive sort on the computed scores hash so
  # that it can be mined for personal achievement information
  def self.sort_hash(qTypeHash)
    result = {}
    # Deep-copy of Hash
    result = Marshal.load(Marshal.dump(qTypeHash))

    result.each do |qType, courseHash|
      courseHash.each do |courseId, userScoreHash|
        user_score_sort_array = userScoreHash.sort {|a, b| b[1][0] <=> a[1][0] }
        result[qType][courseId] = user_score_sort_array
      end
    end
    result
  end

  # This method takes the sorted computed score hash structure and mines
  # it for personal achievement information.
  def self.extract_personal_achievements(csHash, courseIdList, userId)
    # Get all the possible accomplishments from Leaderboard table
    leaderboard_records = Leaderboard.all
    course_accomplishment_hash = {}
    accomplishment_map = {}

    # Create map of accomplishment with its name
    for leaderboardRecord in leaderboard_records
      accomplishment_map[leaderboardRecord.qtype] = leaderboardRecord.name
    end

    cs_sorted_hash = Leaderboard.sort_hash(csHash)

    for courseId in courseIdList
      for accomplishment in accomplishment_map.keys
        # Get score for current questionnaireType/accomplishment, courseId and userId from csHash
        score = csHash.fetch(accomplishment, {}).fetch(courseId, {}).fetch(userId, nil)
        next unless score
        if course_accomplishment_hash[courseId].nil?
          course_accomplishment_hash[courseId] = []
        end
        # Calculate rank of current user
        rank = 1 + cs_sorted_hash[accomplishment][courseId].index([userId, score])
        total = cs_sorted_hash[accomplishment][courseId].length

        course_accomplishment_hash[courseId] << {accomp: accomplishment_map[accomplishment],
                                                 score: score[0],
                                                 rankStr: "#{rank} of #{total}"}
      end
    end
    course_accomplishment_hash
  end

  # Returns string for Top N Leaderboard Heading or accomplishments entry
  def self.leaderboard_heading(qtypeid)
    it_entry = Leaderboard.find_by_qtype(qtypeid)
    if it_entry
      it_entry.name
    else
      "No Entry"
    end
  end
end
