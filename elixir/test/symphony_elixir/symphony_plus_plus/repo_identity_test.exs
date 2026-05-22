defmodule SymphonyElixir.SymphonyPlusPlus.RepoIdentityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity

  test "preserves owner-qualified identity when no bare alias is present" do
    catalog = RepoIdentity.catalog(["alpha/shared"])

    assert RepoIdentity.fields(catalog, "alpha/shared") == %{
             repo_key: "alpha/shared",
             repo_display: "alpha/shared",
             repo_remote: "alpha/shared",
             repo_aliases: ["alpha/shared"]
           }
  end

  test "keeps untrusted bare and owner-qualified repos separate" do
    catalog = RepoIdentity.catalog(["shared", "alpha/shared"])

    assert RepoIdentity.fields(catalog, "shared") == %{
             repo_key: "shared",
             repo_display: "shared",
             repo_remote: nil,
             repo_aliases: ["shared"]
           }

    assert RepoIdentity.fields(catalog, "alpha/shared") == %{
             repo_key: "alpha/shared",
             repo_display: "alpha/shared",
             repo_remote: "alpha/shared",
             repo_aliases: ["alpha/shared"]
           }
  end

  test "keeps bare aliases separate when owner-qualified repos conflict" do
    catalog =
      RepoIdentity.catalog(
        ["shared", "alpha/shared", "beta/shared"],
        trusted_remotes: ["https://github.com/alpha/shared.git"]
      )

    assert RepoIdentity.fields(catalog, "shared") == %{
             repo_key: "shared",
             repo_display: "shared",
             repo_remote: nil,
             repo_aliases: ["shared"]
           }

    assert RepoIdentity.fields(catalog, "alpha/shared") == %{
             repo_key: "alpha/shared",
             repo_display: "alpha/shared",
             repo_remote: "alpha/shared",
             repo_aliases: ["alpha/shared"]
           }

    assert RepoIdentity.fields(catalog, "beta/shared") == %{
             repo_key: "beta/shared",
             repo_display: "beta/shared",
             repo_remote: "beta/shared",
             repo_aliases: ["beta/shared"]
           }
  end

  test "merges bare aliases only for trusted owner-qualified remotes" do
    catalog =
      RepoIdentity.catalog(
        ["symphony-plus-plus", "Pimpmuckl/symphony-plus-plus"],
        trusted_remotes: ["https://github.com/Pimpmuckl/symphony-plus-plus.git"]
      )

    assert RepoIdentity.fields(catalog, "symphony-plus-plus") == %{
             repo_key: "symphony-plus-plus",
             repo_display: "symphony-plus-plus",
             repo_remote: "Pimpmuckl/symphony-plus-plus",
             repo_aliases: ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]
           }

    assert RepoIdentity.fields(catalog, "Pimpmuckl/symphony-plus-plus") == %{
             repo_key: "symphony-plus-plus",
             repo_display: "symphony-plus-plus",
             repo_remote: "Pimpmuckl/symphony-plus-plus",
             repo_aliases: ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]
           }
  end

  test "accepts ssh GitHub remotes as trusted aliases" do
    catalog =
      RepoIdentity.catalog(
        ["symphony-plus-plus", "Pimpmuckl/symphony-plus-plus"],
        trusted_remotes: ["ssh://git@github.com/Pimpmuckl/symphony-plus-plus.git"]
      )

    assert RepoIdentity.fields(catalog, "symphony-plus-plus") == %{
             repo_key: "symphony-plus-plus",
             repo_display: "symphony-plus-plus",
             repo_remote: "Pimpmuckl/symphony-plus-plus",
             repo_aliases: ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]
           }
  end
end
