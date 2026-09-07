# SPDX-FileCopyrightText: 2025 usage_rules contributors <https://github.com/ash-project/usage_rules/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.UsageRules.SearchDocsTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.UsageRules.SearchDocs

  # A hostile hex package publisher controls the documentation fields indexed by
  # search.hexdocs.pm. These reach the terminal through the search task's output.
  @osc52 "\e]52;c;YXR0YWNrZXItY29udHJvbGxlZA==\a"
  @cursor "\e[2A\e[2K\r"

  setup do
    previous_req = Application.get_env(:req, :default_options)

    on_exit(fn ->
      if previous_req do
        Application.put_env(:req, :default_options, previous_req)
      else
        Application.delete_env(:req, :default_options)
      end
    end)

    :ok
  end

  defp stub_search(body) do
    Req.default_options(
      adapter: fn request ->
        response =
          Req.Response.new(
            status: 200,
            headers: %{"content-type" => ["application/json"]},
            body: Jason.encode!(body)
          )

        {request, response}
      end
    )
  end

  test "strips publisher-controlled terminal control sequences from rendered results" do
    stub_search(%{
      "found" => 1,
      "page" => 1,
      "request_params" => %{"per_page" => 10},
      "hits" => [
        %{
          "document" => %{
            "title" => "benign title#{@cursor}forged",
            "package" => "attacker_pkg-1.0.0",
            "type" => "module",
            "ref" => "Attacker.html"
          },
          "highlights" => [
            %{
              "field" => "doc",
              "snippet" => "benign documentation #{@osc52} after"
            }
          ]
        }
      ]
    })

    output =
      capture_io(fn ->
        SearchDocs.run(["needle", "--everywhere"])
      end)

    # None of the attacker's control bytes may reach the terminal. The markdown
    # renderer legitimately emits SGR color codes (`\e[..m`), so we assert on the
    # attacker's specific sequences rather than on all escapes: OSC (`\e]`),
    # cursor movement/erase (`\e[2A`/`\e[2K`), carriage return, and BEL.
    refute String.contains?(output, @osc52)
    refute String.contains?(output, @cursor)
    refute output =~ "\e]"
    refute output =~ "\e[2A"
    refute output =~ "\e[2K"
    refute output =~ "\r"
    refute output =~ "\a"

    # The benign, printable content around the payload is preserved.
    assert output =~ "benign title"
    assert output =~ "forged"
    assert output =~ "benign documentation"
    assert output =~ "after"
  end
end
