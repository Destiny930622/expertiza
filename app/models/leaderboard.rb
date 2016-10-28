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
    assignmentIds = AssignmentParticipant.where(user_id: user_id).pluck(:parent_id)
    noCourseAssignments = Assignment.where(id: assignmentIds, course_id: nil)
  end

  def self.get_assignments_in_courses(courseArray)
    assignmentList = Assignment.where(course_id: courseArray)
  end

  # This method gets all tuples in the Participants table associated
  # hierarchy (qtype => course => user => score)

  def self.get_participant_entries_in_courses(courseArray, user_id)
    assignmentList = []
    assignmentList = get_assignments_in_courses(courseArray)
    independantAssignments = get_independant_assignments(user_id)
    assignmentList.concat(independantAssignments)

    questionnaireHash = get_participants_score(assignmentList)
  end

  # This method gets all tuples in the Participants table associated
  # hierarchy (qtype => course => user => score).
  def self.get_participant_entries_in_assignment(assignmentID)
    assignmentList = []
    assignmentList << Assignment.find(assignmentID)
    questionnaireHash = getParticipantEntriesInAssignmentList(assignmentList)
  end

  # This method returns the participants score grouped by course, grouped by questionnaire type.
  # End result is a hash (qType => (course => (user => score)))
  def self.get_participants_score(assignmentList)
    qTypeHash = {}
    questionnaireResponseTypeHash = {"ReviewResponseMap" => "ReviewQuestionnaire",
                                     "MetareviewResponseMap" => "MetareviewQuestionnaire",
                                     "FeedbackResponseMap" => "AuthorFeedbackQuestionnaire",
                                     "TeammateReviewResponseMap" => "TeammateReviewQuestionnaire",
                                     "BookmarkRatingResponseMap" => "BookmarkRatingQuestionnaire"}

    # Get all participants of the assignment list
    participantList = AssignmentParticipant.where(parent_id: assignmentList.pluck(:id)).uniq

    # Get all teams participated in the given assignment list.
    teamList = Team.where("parent_id IN (?) AND type = ?", assignmentList.pluck(:id), 'AssignmentTeam').uniq

    # Get mapping of participant and team with corresponding assignment.
    # "participant" => {participantId => {"self" => <ParticipantRecord>, "assignment" => <AssignmentRecord>}}
    # "team" => {teamId => <AssignmentRecord>}
    assignmentMap = get_assignment_mapping(assignmentList, participantList, teamList)

    # Aggregate total reviewee list
    revieweeList = []
    revieweeList = participantList.pluck(:id)
    revieweeList.concat(teamList.pluck(:id)).uniq!

    # Get scores from ScoreCache for computed reviewee list.
    scores = ScoreCache.where("reviewee_id IN (?) and object_type IN (?)", revieweeList, questionnaireResponseTypeHash.keys)

    for scoreEntry in scores
      revieweeUserIdList = []
      if assignmentMap["team"].key?(scoreEntry.reviewee_id)
        # Reviewee is a team. Actual Reviewee will be users of the team.
        teamUserIds = TeamsUser.where(team_id: scoreEntry.reviewee_id).pluck(:user_id)
        revieweeUserIdList.concat(teamUserIds)
        courseId = assignmentMap["team"][scoreEntry.reviewee_id].try(:course_id).to_i
      else
        # Reviewee is an individual participant.
        revieweeUserIdList << assignmentMap["participant"][scoreEntry.reviewee_id]["self"].try(:user_id)
        courseId = assignmentMap["participant"][scoreEntry.reviewee_id]["assignment"].try(:course_id).to_i
      end

      questionnaireType = questionnaireResponseTypeHash[scoreEntry.object_type]

      add_score_to_result_ant_hash(qTypeHash, questionnaireType, courseId, revieweeUserIdList, scoreEntry.score)
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
          currentUserScore = qTypeHash[questionnaireType][courseId][revieweeUserId]
          currentTotalScore = currentUserScore[0] * currentUserScore[1]
          currentUserScore[1] += 1
          currentUserScore[0] = (currentTotalScore + scoreEntryScore) / currentUserScore[1]
        end
      end
    end
  end

  # This method creates a mapping of participant and team with corresponding assignment.
  # "participant" => {participantId => {"self" => <ParticipantRecord>, "assignment" => <AssignmentRecord>}}
  # "team" => {teamId => <AssignmentRecord>}
  def self.get_assignment_mapping(assignmentList, participantList, teamList)
    resultHash = {"participant" => {}, "team" => {}}
    assignmentHash = {}
    # Hash all the assignments for later fetching them by assignment.id
    for assignment in assignmentList
      assignmentHash[assignment.id] = assignment
    end
    # Loop over all the participants to get corresponding assignment by parent_id
    for participant in participantList
      resultHash["participant"][participant.id] = {}
      resultHash["participant"][participant.id]["self"] = participant
      resultHash["participant"][participant.id]["assignment"] = assignmentHash[participant.parent_id]
    end
    # Loop over all the teams to get corresponding assignment by parent_id
    for team in teamList
      resultHash["team"][team.id] = assignmentHash[team.parent_id]
    end

    resultHash
 end

  # This method does a destructive sort on the computed scores hash so
  # that it can be mined for personal achievement information
  def self.sort_hash(qTypeHash)
    result = {}
    # Deep-copy of Hash
    result = Marshal.load(Marshal.dump(qTypeHash))

    result.each do |qType, courseHash|
      courseHash.each do |courseId, userScoreHash|
        userScoreSortArray = userScoreHash.sort {|a, b| b[1][0] <=> a[1][0] }
        result[qType][courseId] = userScoreSortArray
      end
    end
    result
  end

  # This method takes the sorted computed score hash structure and mines
  # it for personal achievement information.
  def self.extract_personal_achievements(csHash, courseIdList, userId)
    # Get all the possible accomplishments from Leaderboard table
    leaderboardRecords = Leaderboard.all
    courseAccomplishmentHash = {}
    accomplishmentMap = {}

    # Create map of accomplishment with its name
    for leaderboardRecord in leaderboardRecords
      accomplishmentMap[leaderboardRecord.qtype] = leaderboardRecord.name
    end

    csSortedHash = Leaderboard.sort_hash(csHash)

    for courseId in courseIdList
      for accomplishment in accomplishmentMap.keys
        # Get score for current questionnaireType/accomplishment, courseId and userId from csHash
        score = csHash.fetch(accomplishment, {}).fetch(courseId, {}).fetch(userId, nil)
        next unless score
        if courseAccomplishmentHash[courseId].nil?
          courseAccomplishmentHash[courseId] = []
        end
        # Calculate rank of current user
        rank = 1 + csSortedHash[accomplishment][courseId].index([userId, score])
        total = csSortedHash[accomplishment][courseId].length

        courseAccomplishmentHash[courseId] << {accomp: accomplishmentMap[accomplishment],
                                               score: score[0],
                                               rankStr: "#{rank} of #{total}"}
      end
    end
    courseAccomplishmentHash
  end

  # Returns string for Top N Leaderboard Heading or accomplishments entry
  def self.leaderboard_heading(qtypeid)
    ltEntry = Leaderboard.find_by_qtype(qtypeid)
    if ltEntry
      ltEntry.name
    else
      "No Entry"
    end
  end
end
