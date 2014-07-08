defmodule Earmark.Inline do

  
  import Earmark.Helpers

  alias Earmark.Context


  @doc false
  def convert(src, context) when is_list(src) do  
    convert(Enum.join(src, "\n"), context)
  end

  def convert(src, context) do
    convert_each(src, context, [])
  end

  defp convert_each("", _context, result) do
    result |> Enum.reverse |> Enum.join
  end

  defp convert_each(src, context, result) do
    renderer = context.options.renderer

    cond do
      # escape
      match = Regex.run(context.rules.escape, src) ->
        [ match, escaped ] = match
        convert_each(behead(src, match), context, [escaped | result])
    
      # autolink
      match = Regex.run(context.rules.autolink, src) ->
        [ match, link, protocol ] = match
        { href, text } = convert_autolink(link, protocol)
        out = renderer.link(href, text)
        convert_each(behead(src, match), context, [ out | result ])

      # url (gfm)
      match = Regex.run(context.rules.url, src) ->
        [ match, href ] = match
        text = escape(href)
        out = renderer.link(href, text)
        convert_each(behead(src, match), context, [ out | result ])

      # tag
      match = Regex.run(context.rules.tag, src) ->
        [ match ] = match
        out = context.options.do_sanitize.(match)
        convert_each(behead(src, match), context, [ out | result ])

      # link
      match = Regex.run(context.rules.link, src) ->
        { match, text, href, title } = case match do
          [ match, text, href ]        -> { match, text, href, nil }
          [ match, text, href, title ] -> { match, text, href, title }
        end
        out = output_image_or_link(context, match, text, href, title)
        convert_each(behead(src, match), context, [ out | result ])


      # reflink
      match = Regex.run(context.rules.reflink, src) ->
        { match, alt_text, id } = case match do
          [ match, id ]           -> { match, nil, id }
          [ match, alt_text, id ] -> { match, alt_text, id }
        end
        out = reference_link(context, match, alt_text, id)
        convert_each(behead(src, match), context, [ out | result ])

      # nolink
      match = Regex.run(context.rules.nolink, src) ->
        [ match, id ] = match
        out = reference_link(context, match, id, id)
        convert_each(behead(src, match), context, [ out | result ])
   

      # strikethrough (gfm)
      match = Regex.run(context.rules.strikethrough, src) ->
        [ match, content ] = match                             
        out = renderer.strikethrough(convert(content, context))
        convert_each(behead(src, match), context, [ out | result ])


      # strong
      match = Regex.run(context.rules.strong, src) ->
        { match, content } = case match do
          [ m, _, c ] -> {m, c}
          [ m, c ]    -> {m, c}
        end
        out = renderer.strong(convert(content, context))
        convert_each(behead(src, match), context, [ out | result ])

      # em
      match = Regex.run(context.rules.em, src) ->
        { match, content } = case match do
          [ m, _, c ] -> {m, c}
          [ m, c ]    -> {m, c}
        end
        out = renderer.em(convert(content, context))
        convert_each(behead(src, match), context, [ out | result ])


      # code
      match = Regex.run(context.rules.code, src) ->
        [match, _, content] = match
        content = String.strip(content)  # this from Gruber
        out = renderer.codespan(escape(content, true))
        convert_each(behead(src, match), context, [ out | result ])

      # br
      match = Regex.run(context.rules.br, src, return: :index) ->
        out = renderer.br()
        [ {0, match_len} ] = match
        convert_each(behead(src, match_len), context, [ out | result ])


      # text
      match = Regex.run(context.rules.text, src) ->
        [ match ] = match                             
        out = escape(context.options.do_smartypants.(match))
        convert_each(behead(src, match), context, [ out | result ])

      # No match
      true ->
        location = String.slice(src, 0, 100)
        raise("Failed to parse inline starting at: #{inspect(location)}")
    end
  end

  defp convert_autolink(link, _separator = "@") do
    link = (if String.at(link, 6) == ":", do: behead(link, 7), else: link)
    text = mangle_link(link)
    href = mangle_link("mailto:") <> text
    { href, text }
  end

  defp convert_autolink(link, _separator) do
    link = escape(link)
    { link, link }
  end

  @doc """
  Smartypants transformations convert quotes to the appropriate curly
  variants, and -- and ... to – and …
  """

  def smartypants(text) do
    text
    |> replace(~r{--}, "—")
    |> replace(~r{(^|[-—/\(\[\{"”“\s])'}, "\\1‘")
    |> replace(~r{\'}, "’")
    |> replace(~r{(^|[-—/\(\[\{‘\s])\"}, "\\1“")
    |> replace(~r{"}, "”")
    |> replace(~r{\.\.\.}, "…")
  end


  @doc false
  def mangle_link(link) do
    link
  end                


  defp output_image_or_link(context, "!" <> _, text, href, title) do
    output_image(context.options.renderer, text, href, title)
  end

  defp output_image_or_link(context, _, text, href, title) do
    output_link(context, text, href, title)
  end

  defp output_link(context, text, href, title) do
    href = escape(href)
    title = if title, do: escape(title), else: nil
    context.options.renderer.link(href, convert_each(text, context, []), title)
  end

  defp output_image(renderer, text, href, title) do
    href = escape(href)
    title = if title, do: escape(title), else: nil
    renderer.image(href, escape(text), title)
  end

  defp reference_link(context, match, alt_text, id) do
    id = id |> replace(~r{\s+}, " ") |> String.downcase
    case Dict.fetch(context.links, id) do
      {:ok, link } -> output_image_or_link(context, match, alt_text, link.url, link.title)
      _            -> match
    end
  end


  ##############################################################################
  # Handle adding option specific rules and processors                         #
  ##############################################################################

  defp noop(text), do: text
                        
  @doc false
  # this is called by the command line processor to update
  # the inline-specific rules in light of any options
  def update_context(context =  %Context{options: options}) do
    context = %{ context | rules: rules_for(options) }
    context = if options.smartypants do
      put_in(context.options.do_smartypants, &smartypants/1)
    else
      put_in(context.options.do_smartypants, &noop/1)
    end      

    if options.sanitize do
      put_in(context.options.do_sanitize, &escape/1)
    else 
      put_in(context.options.do_sanitize, &noop/1)
    end
  end


  @inside  ~S{(?:\[[^\]]*\]|[^\[\]]|\](?=[^\[]*\]))*}
  @href    ~S{\s*<?([\s\S]*?)>?(?:\s+['"]([\s\S]*?)['"])?\s*}  #"

  @code ~r{^
			(`+)		# $1 = Opening run of `
			(.+?)		# $2 = The code block
			(?<!`)
			\1			# Matching closer
			(?!`)
  }x


  defp basic_rules do
   [
    escape:   ~r{^\\([\\`*\{\}\[\]()\#+\-.!_>])},
    autolink: ~r{^<([^ >]+(@|:\/)[^ >]+)>},
    url:      ~r{\z\A},  # noop
    tag:      ~r{^<!--[\s\S]*?-->|^<\/?\w+(?:"[^"]*"|'[^']*'|[^'">])*?>},
    link:     ~r{^!?\[(#{@inside})\]\(#{@href}\)},
    reflink:  ~r{^!?\[(#{@inside})\]\s*\[([^\]]*)\]},
    nolink:   ~r{^!?\[((?:\[[^\]]*\]|[^\[\]])*)\]},
    strong:   ~r{^__([\s\S]+?)__(?!_)|^\*\*([\s\S]+?)\*\*(?!\*)},
    em:       ~r{^\b_((?:__|[\s\S])+?)_\b|^\*((?:\*\*|[\s\S])+?)\*(?!\*)},
    code:     @code,
    br:       ~r<^ {2,}\n(?!\s*$)>,
    text:     ~r<^[\s\S]+?(?=[\\<!\[_*`]| {2,}\n|$)>,
    strikethrough: ~r{\z\A}   # noop
    ]
  end 

  defp rules_for(options) do
    rule_updates = []
    if options.gfm do
      rule_updates = [
        escape:        ~r{^\\([\\`*\{\}\[\]()\#+\-.!_>~|])},
        url:           ~r{^(https?:\/\/[^\s<]+[^<.,:;\"\')\]\s])},
        strikethrough: ~r{^~~(?=\S)([\s\S]*?\S)~~},
        text:          ~r{^[\s\S]+?(?=[\\<!\[_*`~]|https?://| \{2,\}\n|$)}
      ]
      if options.breaks do
        break_updates = [
          br:    ~r{^ *\n(?!\s*$)},
          text:  ~r{^[\s\S]+?(?=[\\<!\[_*`~]|https?://| *\n|$)}
        ]
        rule_updates = Keyword.merge(rule_updates, break_updates)  
      end
    else
      if options.pedantic do
        rule_updates = [
          strong: ~r{^__(?=\S)([\s\S]*?\S)__(?!_)|^\*\*(?=\S)([\s\S]*?\S)\*\*(?!\*)},
          em:     ~r{^_(?=\S)([\s\S]*?\S)_(?!_)|^\*(?=\S)([\s\S]*?\S)\*(?!\*)}
        ]
      end
    end  
    Keyword.merge(basic_rules, rule_updates)
    |> Enum.into %{}
  end
end