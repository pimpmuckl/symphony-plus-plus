defmodule SymphonyElixir.SymphonyPlusPlus.HumanDecisionPromptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt

  test "structured prompt answer rejects unknown option ids" do
    prompt = %{
      "tl_dr" => "Choose a path.",
      "details" => "The worker needs a durable answer.",
      "options" => [
        %{"id" => "continue", "label" => "Continue", "answer" => "Continue with the proposed path."}
      ]
    }

    assert {:error, :invalid_answer_choice} =
             HumanDecisionPrompt.answer_text_result(prompt, %{"answer_choice" => "unknown"})

    assert HumanDecisionPrompt.answer_text(prompt, %{"answer_choice" => "unknown"}) == ""
  end

  test "custom redirect answer requires replacement guidance" do
    prompt = %{
      "tl_dr" => "Choose a path.",
      "details" => "The worker needs a durable answer.",
      "options" => [
        %{"id" => "continue", "label" => "Continue", "answer" => "Continue with the proposed path."}
      ],
      "custom_redirect_label" => "No, and tell the agent what to do differently"
    }

    assert {:error, :missing_custom_redirect_note} =
             HumanDecisionPrompt.answer_text_result(prompt, %{
               "answer_choice" => HumanDecisionPrompt.custom_redirect_choice_id()
             })

    assert {:ok, "Use the smaller fallback path."} =
             HumanDecisionPrompt.answer_text_result(prompt, %{
               "answer_choice" => HumanDecisionPrompt.custom_redirect_choice_id(),
               "answer_note" => "Use the smaller fallback path."
             })
  end

  test "structured custom redirect works with the default label contract" do
    prompt = %{
      "tl_dr" => "Choose a path.",
      "details" => "The worker needs a durable answer.",
      "options" => [
        %{"id" => "continue", "label" => "Continue", "answer" => "Continue with the proposed path."}
      ]
    }

    assert {:ok, "Use a different scoped path."} =
             HumanDecisionPrompt.answer_text_result(prompt, %{
               "answer_choice" => HumanDecisionPrompt.custom_redirect_choice_id(),
               "answer_note" => "Use a different scoped path."
             })
  end

  test "structured option id redirect behaves like a normal option" do
    prompt = %{
      "tl_dr" => "Choose a path.",
      "details" => "The worker needs a durable answer.",
      "options" => [
        %{"id" => "redirect", "label" => "Redirect internally", "answer" => "Use the structured redirect option."}
      ]
    }

    assert {:ok, "Use the structured redirect option."} =
             HumanDecisionPrompt.answer_text_result(prompt, %{"answer_choice" => "redirect"})
  end

  test "structured prompts ignore stale raw answer fields" do
    prompt = %{
      "tl_dr" => "Choose a path.",
      "details" => "The worker needs a durable answer.",
      "options" => [
        %{"id" => "continue", "label" => "Continue", "answer" => "Continue with the structured path."}
      ]
    }

    assert {:ok, "Continue with the structured path. Keep the focused fix scoped."} =
             HumanDecisionPrompt.answer_text_result(prompt, %{
               "answer" => "Stale autofilled raw answer.",
               "answer_choice" => "continue",
               "answer_note" => "Keep the focused fix scoped."
             })

    assert {:error, :missing_answer} =
             HumanDecisionPrompt.answer_text_result(prompt, %{"answer" => "Stale autofilled raw answer."})
  end

  test "plain fallback answers still accept generic option ids" do
    assert HumanDecisionPrompt.answer_text(nil, %{"answer_choice" => "narrow", "answer_note" => "Keep it scoped."}) ==
             "Narrow the scope before continuing. Keep it scoped."
  end

  test "plain fallback redirect keeps requiring a replacement note" do
    assert {:error, :missing_custom_redirect_note} =
             HumanDecisionPrompt.answer_text_result(nil, %{"answer_choice" => "redirect"})
  end
end
