class ChallengeSignupTagSummary < Struct.new(:id, :name, :requests, :offers)

  # Prioritize tags with the fewest offers and most requests
  # If they have the same number of offers and requests, sort by name
  def <=>(other)
    if self.offers == other.offers
      if self.requests == other.requests
        self.name <=> other.name
      else
        other.requests <=> self.requests
      end
    else
      self.offers <=> other.offers
    end
  end

end
