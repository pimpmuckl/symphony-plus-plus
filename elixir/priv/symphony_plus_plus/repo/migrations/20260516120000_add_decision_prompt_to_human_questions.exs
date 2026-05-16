defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddDecisionPromptToHumanQuestions do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_request_clarification_questions) do
      add(:decision_prompt, :map)
    end

    alter table(:sympp_guidance_requests) do
      add(:decision_prompt, :map)
    end
  end
end
