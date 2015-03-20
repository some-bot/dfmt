//          Copyright Brian Schott 2015.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dfmt.main;

import std.stdio;

import std.d.lexer;
import std.d.parser;
import std.d.formatter;
import std.d.ast;
import std.array;

version (NoMain)
{
}
else
{
    int main(string[] args)
    {
        import std.getopt : getopt;

        bool inplace = false;
        bool show_usage = false;
        FormatterConfig formatterConfig;
        getopt(args, "help|h", &show_usage, "inplace", &inplace, "tabs|t",
            &formatterConfig.useTabs, "braces", &formatterConfig.braceStyle);
        if (show_usage)
        {
            import std.path : baseName;

            writef(USAGE, baseName(args[0]));
            return 0;
        }
        File output = stdout;
        ubyte[] buffer;
        args.popFront();
        if (args.length == 0)
        {
            ubyte[4096] inputBuffer;
            ubyte[] b;
            while (true)
            {
                b = stdin.rawRead(inputBuffer);
                if (b.length)
                    buffer ~= b;
                else
                    break;
            }
            format("stdin", buffer, output.lockingTextWriter(), &formatterConfig);
        }
        else
        {
            import std.file : dirEntries, isDir, SpanMode;

            if (args.length >= 2)
                inplace = true;
            while (args.length > 0)
            {
                const path = args.front;
                args.popFront();
                if (isDir(path))
                {
                    inplace = true;
                    foreach (string name; dirEntries(path, "*.d", SpanMode.depth))
                    {
                        args ~= name;
                    }
                    continue;
                }
                File f = File(path);
                buffer = new ubyte[](cast(size_t) f.size);
                f.rawRead(buffer);
                if (inplace)
                    output = File(path, "wb");
                format(path, buffer, output.lockingTextWriter(), &formatterConfig);
            }
        }
        return 0;
    }
}

private:

immutable USAGE = "usage: %s [--inplace] [<path>...]
Formats D code.

    --inplace        Change file in-place instead of outputing to stdout
                     (implicit in case of multiple files)
    --tabs | -t      Use tabs instead of spaces for indentation
    --braces=allman  Use Allman indent style (default)
    --braces=otbs    Use the One True Brace Style
    --help | -h      Display this help and exit
";

void format(OutputRange)(string source_desc, ubyte[] buffer, OutputRange output,
    FormatterConfig* formatterConfig)
{
    LexerConfig config;
    config.stringBehavior = StringBehavior.source;
    config.whitespaceBehavior = WhitespaceBehavior.skip;
    LexerConfig parseConfig;
    parseConfig.stringBehavior = StringBehavior.source;
    parseConfig.whitespaceBehavior = WhitespaceBehavior.skip;
    StringCache cache = StringCache(StringCache.defaultBucketCount);
    ASTInformation astInformation;
    auto parseTokens = getTokensForParser(buffer, parseConfig, &cache);
    auto mod = parseModule(parseTokens, source_desc);
    auto visitor = new FormatVisitor(&astInformation);
    visitor.visit(mod);
    astInformation.cleanup();
    auto tokens = byToken(buffer, config, &cache).array();
    auto depths = generateDepthInfo(tokens);
    auto tokenFormatter = TokenFormatter!OutputRange(tokens, depths, output,
        &astInformation, formatterConfig);
    tokenFormatter.format();
}

immutable(short[]) generateDepthInfo(const Token[] tokens)
{
    import std.exception : assumeUnique;

    short[] retVal = new short[](tokens.length);
    short depth = 0;
    foreach (i, ref t; tokens)
    {
        switch (t.type)
        {
        case tok!"{":
        case tok!"(":
        case tok!"[":
            depth++;
            break;
        case tok!"}":
        case tok!")":
        case tok!"]":
            depth--;
            break;
        default:
            break;
        }
        retVal[i] = depth;
    }
    return assumeUnique(retVal);
}

struct TokenFormatter(OutputRange)
{
    /**
     * Params:
     *     tokens = the tokens to format
     *     output = the output range that the code will be formatted to
     *     astInformation = information about the AST used to inform formatting
     *         decisions.
     */
    this(const(Token)[] tokens, immutable short[] depths, OutputRange output,
        ASTInformation* astInformation, FormatterConfig* config)
    {
        this.tokens = tokens;
        this.depths = depths;
        this.output = output;
        this.astInformation = astInformation;
        this.config = config;
    }

    /// Runs the foramtting process
    void format()
    {
        while (index < tokens.length)
            formatStep();
    }

private:

    void formatStep()
    {
        assert(index < tokens.length);
        if (currentIs(tok!"comment"))
        {
            formatComment();
        }
        else if (isStringLiteral(current.type) || isNumberLiteral(current.type)
                || currentIs(tok!"characterLiteral"))
        {
            writeToken();
            if (index < tokens.length)
            {
                immutable t = tokens[index].type;
                if (t == tok!"identifier" || isStringLiteral(t)
                        || isNumberLiteral(t) || t == tok!"characterLiteral")
                    write(" ");
            }
        }
        else if (currentIs(tok!"module") || currentIs(tok!"import"))
        {
            formatModuleOrImport();
        }
        else if (currentIs(tok!"return"))
        {
            writeToken();
            if (!currentIs(tok!";") && !currentIs(tok!")"))
                write(" ");
        }
        else if (currentIs(tok!"with"))
        {
            if (indents.length == 0 || indents.top != tok!"switch")
                indents.push(tok!"with");
            writeToken();
            write(" ");
            if (currentIs(tok!"("))
                writeParens(false);
            if (!currentIs(tok!"switch") && !currentIs(tok!"with")
                    && !currentIs(tok!"{") && !(currentIs(tok!"final") && peekIs(tok!"switch")))
            {
                newline();
            }
            else if (!currentIs(tok!"{"))
                write(" ");
        }
        else if (currentIs(tok!"switch"))
        {
            formatSwitch();
        }
        else if (currentIs(tok!"extern") && peekIs(tok!"("))
        {
            writeToken();
            write(" ");
        }
        else if ((isBlockHeader() || currentIs(tok!"version")
                || currentIs(tok!"debug")) && peekIs(tok!"(", false))
        {
            formatBlockHeader();
        }
        else if (currentIs(tok!"else"))
        {
            formatElse();
        }
        else if (isKeyword(current.type))
        {
            formatKeyword();
        }
        else if (isBasicType(current.type))
        {
            writeToken();
            if (currentIs(tok!"identifier") || isKeyword(current.type))
                write(" ");
        }
        else if (isOperator(current.type))
        {
            formatOperator();
        }
        else if (currentIs(tok!"identifier"))
        {
            writeToken();
            if (index < tokens.length && (currentIs(tok!"identifier")
                    || isKeyword(current.type) || isBasicType(current.type) || currentIs(tok!"@")))
            {
                write(" ");
            }
        }
        else if (currentIs(tok!"scriptLine"))
        {
            writeToken();
            newline();
        }
        else
            writeToken();
    }

    void formatComment()
    {
        immutable bool currIsSlashSlash = tokens[index].text[0 .. 2] == "//";
        immutable prevTokenEndLine = index == 0 ? size_t.max : tokenEndLine(tokens[index - 1]);
        immutable size_t currTokenLine = tokens[index].line;
        if (index > 0)
        {
            immutable t = tokens[index - 1].type;
            immutable canAddNewline = currTokenLine - prevTokenEndLine < 1;
            if (prevTokenEndLine == currTokenLine || (t == tok!")" && peekIs(tok!"{")))
                write(" ");
            else if (t != tok!";" && t != tok!"}" && canAddNewline)
            {
                newline();
            }
        }
        writeToken();
        immutable j = justAddedExtraNewline;
        if (currIsSlashSlash)
        {
            newline();
            justAddedExtraNewline = j;
        }
        else if (index < tokens.length)
        {
            if (index < tokens.length && prevTokenEndLine == tokens[index].line)
            {
                if (!currentIs(tok!"{"))
                    write(" ");
            }
            else if (!currentIs(tok!"{"))
                newline();
        }
        else
            newline();
    }

    void formatModuleOrImport()
    {
        auto t = current.type;
        writeToken();
        if (currentIs(tok!"("))
        {
            writeParens(false);
            return;
        }
        write(" ");
        while (index < tokens.length)
        {
            if (currentIs(tok!";"))
            {
                writeToken();
                if (index >= tokens.length)
                {
                    newline();
                    break;
                }
                if (currentIs(tok!"comment") && current.line == peekBack().line)
                {
                    break;
                }
                else if ((t == tok!"import" && !currentIs(tok!"import")))
                {
                    write("\n");
                    currentLineLength = 0;
                    justAddedExtraNewline = true;
                    newline();
                }
                else
                    newline();
                break;
            }
            else if (currentIs(tok!","))
            {
                // compute length until next , or ;
                int lengthOfNextChunk = INVALID_TOKEN_LENGTH;
                for (size_t i = index + 1; i < tokens.length; i++)
                {
                    if (tokens[i].type == tok!"," || tokens[i].type == tok!";")
                        break;
                    const len = tokenLength(tokens[i]);
                    assert(len >= 0);
                    lengthOfNextChunk += len;
                }
                assert(lengthOfNextChunk > 0);
                writeToken();
                if (currentLineLength + 1 + lengthOfNextChunk >= config.columnSoftLimit)
                {
                    pushWrapIndent(tok!",");
                    newline();
                }
                else
                    write(" ");
            }
            else
                formatStep();
        }
    }

    void formatLeftParenOrBracket()
    {
        immutable p = tokens[index].type;
        regenLineBreakHintsIfNecessary(index);
        writeToken();
        if (p == tok!"(")
        {
            spaceAfterParens = true;
            parenDepth++;
        }
        immutable bool arrayInitializerStart = p == tok!"[" && linebreakHints.length != 0
            && astInformation.arrayStartLocations.canFindIndex(tokens[index - 1].index);
        if (arrayInitializerStart)
        {
            // Use the close bracket as the indent token to distinguish
            // the array initialiazer from an array index in the newling
            // handling code
            pushWrapIndent(tok!"]");
            newline();
            immutable size_t j = expressionEndIndex(index);
            linebreakHints = chooseLineBreakTokens(index, tokens[index .. j],
                depths[index .. j], config, currentLineLength, indentLevel);
        }
        else if (!currentIs(tok!")") && !currentIs(tok!"]")
                && (linebreakHints.canFindIndex(index - 1) || (linebreakHints.length == 0
                && currentLineLength > config.columnHardLimit)))
        {
            pushWrapIndent(p);
            newline();
        }
    }

    void formatRightParen()
    {
        parenDepth--;
        if (parenDepth == 0)
            while (indents.length > 0 && isWrapIndent(indents.top))
                indents.pop();
        if (parenDepth == 0 && (peekIs(tok!"in") || peekIs(tok!"out") || peekIs(tok!"body")))
        {
            writeToken(); // )
            newline();
            writeToken(); // in/out/body
        }
        else if (peekIsLiteralOrIdent() || peekIsBasicType() || peekIsKeyword())
        {
            writeToken();
            if (spaceAfterParens || parenDepth > 0)
                write(" ");
        }
        else if ((peekIsKeyword() || peekIs(tok!"@")) && spaceAfterParens)
        {
            writeToken();
            write(" ");
        }
        else
            writeToken();
    }

    void formatAt()
    {
        writeToken();
        if (currentIs(tok!"identifier"))
            writeToken();
        if (currentIs(tok!"("))
        {
            writeParens(false);
            if (index < tokens.length && tokens[index - 1].line < tokens[index].line)
                newline();
            else
                write(" ");
        }
        else if (index < tokens.length && (currentIs(tok!"@") || !isOperator(tokens[index].type)))
            write(" ");
    }

    void formatColon()
    {
        if (astInformation.caseEndLocations.canFindIndex(current.index)
                || astInformation.attributeDeclarationLines.canFindIndex(current.line))
        {
            writeToken();
            if (!currentIs(tok!"{"))
                newline();
        }
        else if (peekBackIs(tok!"identifier") && (peekBack2Is(tok!"{", true)
                || peekBack2Is(tok!"}", true) || peekBack2Is(tok!";", true)
                || peekBack2Is(tok!":", true)) && !(isBlockHeader(1) && !peekIs(tok!"if")))
        {
            writeToken();
            if (!currentIs(tok!"{"))
                newline();
        }
        else
        {
            regenLineBreakHintsIfNecessary(index);
            if (peekIs(tok!".."))
                writeToken();
            else if (isBlockHeader(1) && !peekIs(tok!"if"))
            {
                writeToken();
                write(" ");
            }
            else if (linebreakHints.canFindIndex(index))
            {
                pushWrapIndent();
                newline();
                writeToken();
                write(" ");
            }
            else
            {
                write(" : ");
                index++;
            }
        }
    }

    void formatSemicolon()
    {
        if ((parenDepth > 0 && sBraceDepth == 0) || (sBraceDepth > 0 && niBraceDepth > 0))
        {
            if (currentLineLength > config.columnSoftLimit)
            {
                writeToken();
                pushWrapIndent(tok!";");
                newline();
            }
            else
            {
                if (!(peekIs(tok!";") || peekIs(tok!")") || peekIs(tok!"}")))
                    write("; ");
                else
                    write(";");
                index++;
            }
        }
        else
        {
            writeToken();
            linebreakHints = [];
            newline();
        }
    }

    void formatLeftBrace()
    {
        import std.algorithm : map, sum;

        if (astInformation.structInitStartLocations.canFindIndex(tokens[index].index))
        {
            sBraceDepth++;
            auto e = expressionEndIndex(index);
            immutable int l = currentLineLength + tokens[index .. e].map!(a => tokenLength(a)).sum();
            writeToken();
            if (l > config.columnSoftLimit)
            {
                indents.push(tok!"{");
                newline();
            }
            else
                niBraceDepth++;
        }
        else if (astInformation.funLitStartLocations.canFindIndex(tokens[index].index))
        {
            sBraceDepth++;
            if (peekBackIs(tok!")"))
                write(" ");
            auto e = expressionEndIndex(index);
            immutable int l = currentLineLength + tokens[index .. e].map!(a => tokenLength(a)).sum();
            writeToken();
            if (l > config.columnSoftLimit)
            {
                indents.push(tok!"{");
                newline();
            }
            else
            {
                niBraceDepth++;
                write(" ");
            }
        }
        else
        {
            if (!justAddedExtraNewline && !peekBackIs(tok!"{")
                    && !peekBackIs(tok!"}") && !peekBackIs(tok!";") && !peekBackIs(tok!";"))
            {
                if (config.braceStyle == BraceStyle.otbs)
                {
                    if (!astInformation.structInitStartLocations.canFindIndex(tokens[index].index)
                            && !astInformation.funLitStartLocations.canFindIndex(
                            tokens[index].index))
                    {
                        while (indents.length && isWrapIndent(indents.top))
                            indents.pop();
                        indents.push(tok!"{");
                        if (index == 1 || peekBackIs(tok!":", true)
                                || peekBackIs(tok!"{", true) || peekBackIs(tok!"}", true)
                                || peekBackIs(tok!")", true) || peekBackIs(tok!";",
                                true))
                        {
                            indentLevel = indents.indentSize - 1;
                        }
                    }
                    write(" ");
                }
                else if (index > 0 && (!peekBackIs(tok!"comment")
                        || tokens[index - 1].text[0 .. 2] != "//"))
                    newline();
            }
            writeToken();
            newline();
            linebreakHints = [];
        }
    }

    void formatRightBrace()
    {
        if (astInformation.structInitEndLocations.canFindIndex(tokens[index].index))
        {
            if (sBraceDepth > 0)
                sBraceDepth--;
            if (niBraceDepth > 0)
                niBraceDepth--;
            writeToken();
        }
        else if (astInformation.funLitEndLocations.canFindIndex(tokens[index].index))
        {
            if (niBraceDepth > 0)
            {
                if (!peekBackIsSlashSlash())
                    write(" ");
                niBraceDepth--;
            }
            if (sBraceDepth > 0)
                sBraceDepth--;
            writeToken();
        }
        else
        {
            // Silly hack to format enums better.
            if (peekBackIsLiteralOrIdent() || peekBackIs(tok!")", true)
                    || (peekBackIs(tok!",", true) && !peekBackIsSlashSlash))
                newline();
            write("}");
            if (index < tokens.length - 1
                    && astInformation.doubleNewlineLocations.canFindIndex(tokens[index].index)
                    && !peekIs(tok!"}") && !peekIs(tok!";"))
            {
                write("\n");
                currentLineLength = 0;
                justAddedExtraNewline = true;
            }
            if (config.braceStyle == BraceStyle.otbs && currentIs(tok!"else"))
                write(" ");
            if (!peekIs(tok!",") && !peekIs(tok!")") && !peekIs(tok!";"))
            {
                index++;
                newline();
            }
            else
                index++;
        }
    }

    void formatSwitch()
    {
        if (indents.length > 0 && indents.top == tok!"with")
            indents.pop();
        indents.push(tok!"switch");
        writeToken(); // switch
        write(" ");
    }

    void formatBlockHeader()
    {
        immutable bool a = !currentIs(tok!"version") && !currentIs(tok!"debug");
        immutable bool b = a
            || astInformation.conditionalWithElseLocations.canFindIndex(current.index);
        immutable bool shouldPushIndent = b
            || astInformation.conditionalStatementLocations.canFindIndex(current.index);
        if (shouldPushIndent)
            indents.push(current.type);
        writeToken();
        write(" ");
        writeParens(false);
        if (currentIs(tok!"switch") || (currentIs(tok!"final") && peekIs(tok!"switch")))
            write(" ");
        else if (currentIs(tok!"comment"))
            formatStep();
        else if (!shouldPushIndent)
        {
            if (!currentIs(tok!"{") && !currentIs(tok!";"))
                write(" ");
        }
        else if (!currentIs(tok!"{") && !currentIs(tok!";"))
            newline();
    }

    void formatElse()
    {
        writeToken();
        if (currentIs(tok!"if") || (currentIs(tok!"static") && peekIs(tok!"if"))
                || currentIs(tok!"version"))
        {
            if (indents.top() == tok!"if" || indents.top == tok!"version")
                indents.pop();
            write(" ");
        }
        else if (!currentIs(tok!"{") && !currentIs(tok!"comment"))
        {
            if (indents.top() == tok!"if" || indents.top == tok!"version")
                indents.pop();
            indents.push(tok!"else");
            newline();
        }
    }

    void formatKeyword()
    {
        switch (current.type)
        {
        case tok!"default":
            writeToken();
            break;
        case tok!"cast":
            writeToken();
            break;
        case tok!"in":
        case tok!"is":
            writeToken();
            if (!currentIs(tok!"(") && !currentIs(tok!"{"))
                write(" ");
            break;
        case tok!"case":
            writeToken();
            if (!currentIs(tok!";"))
                write(" ");
            break;
        case tok!"enum":
            indents.push(tok!"enum");
            writeToken();
            if (!currentIs(tok!":"))
                write(" ");
            break;
        default:
            if (index + 1 < tokens.length)
            {
                if (!peekIs(tok!"@") && peekIsOperator())
                    writeToken();
                else
                {
                    writeToken();
                    write(" ");
                }
            }
            else
                writeToken();
            break;
        }
    }

    void formatOperator()
    {
        import std.algorithm : canFind;

        switch (current.type)
        {
        case tok!"*":
            if (astInformation.spaceAfterLocations.canFindIndex(current.index))
            {
                writeToken();
                if (!currentIs(tok!"*") && !currentIs(tok!")")
                        && !currentIs(tok!"[") && !currentIs(tok!",") && !currentIs(tok!";"))
                {
                    write(" ");
                }
                break;
            }
            else if (!astInformation.unaryLocations.canFindIndex(current.index))
                goto binary;
            else
                writeToken();
            break;
        case tok!"~":
            if (peekIs(tok!"this"))
            {
                if (!(index == 0 || peekBackIs(tok!"{", true)
                        || peekBackIs(tok!"}", true) || peekBackIs(tok!";", true)))
                {
                    write(" ");
                }
                writeToken();
                break;
            }
            else
                goto case;
        case tok!"&":
        case tok!"+":
        case tok!"-":
            if (astInformation.unaryLocations.canFindIndex(current.index))
            {
                writeToken();
                break;
            }
            goto binary;
        case tok!"[":
        case tok!"(":
            formatLeftParenOrBracket();
            break;
        case tok!")":
            formatRightParen();
            break;
        case tok!"@":
            formatAt();
            break;
        case tok!"!":
            if (peekIs(tok!"is") && !(peekBackIs(tok!"(") || peekBackIs(tok!"=")))
                write(" ");
            goto case;
        case tok!"...":
        case tok!"++":
        case tok!"--":
        case tok!"$":
            writeToken();
            break;
        case tok!":":
            formatColon();
            break;
        case tok!"]":
            while (indents.length && isWrapIndent(indents.top))
                indents.pop();
            if (indents.length && indents.top == tok!"]")
                newline();
            writeToken();
            if (currentIs(tok!"identifier"))
                write(" ");
            break;
        case tok!";":
            formatSemicolon();
            break;
        case tok!"{":
            formatLeftBrace();
            break;
        case tok!"}":
            formatRightBrace();
            break;
        case tok!".":
            if (linebreakHints.canFind(index) || (linebreakHints.length == 0
                    && currentLineLength + nextTokenLength() > config.columnHardLimit))
            {
                pushWrapIndent();
                newline();
            }
            writeToken();
            break;
        case tok!",":
            formatComma();
            break;
        case tok!"&&":
        case tok!"||":
            regenLineBreakHintsIfNecessary(index);
            goto case;
        case tok!"=":
        case tok!">=":
        case tok!">>=":
        case tok!">>>=":
        case tok!"|=":
        case tok!"-=":
        case tok!"/=":
        case tok!"*=":
        case tok!"&=":
        case tok!"%=":
        case tok!"+=":
        case tok!"^^":
        case tok!"^=":
        case tok!"^":
        case tok!"~=":
        case tok!"<<=":
        case tok!"<<":
        case tok!"<=":
        case tok!"<>=":
        case tok!"<>":
        case tok!"<":
        case tok!"==":
        case tok!"=>":
        case tok!">>>":
        case tok!">>":
        case tok!">":
        case tok!"|":
        case tok!"!<=":
        case tok!"!<>=":
        case tok!"!<>":
        case tok!"!<":
        case tok!"!=":
        case tok!"!>=":
        case tok!"!>":
        case tok!"?":
        case tok!"/":
        case tok!"..":
        case tok!"%":
        binary:
            if (linebreakHints.canFind(index) || peekIs(tok!"comment", false))
            {
                pushWrapIndent();
                newline();
            }
            else
                write(" ");
            writeToken();
            write(" ");
            break;
        default:
            writeToken();
            break;
        }
    }

    void formatComma()
    {
        import std.algorithm : canFind;

        regenLineBreakHintsIfNecessary(index);
        if (indents.indentToMostRecent(tok!"enum") != -1 && !peekIs(tok!"}")
                && indents.top == tok!"{" && parenDepth == 0)
        {
            writeToken();
            newline();
        }
        else if (!peekIs(tok!"}") && (linebreakHints.canFind(index)
                || (linebreakHints.length == 0 && currentLineLength > config.columnSoftLimit)))
        {
            writeToken();
            pushWrapIndent(tok!",");
            newline();
        }
        else
        {
            writeToken();
            if (!currentIs(tok!")", false) && !currentIs(tok!"]", false)
                    && !currentIs(tok!"}", false) && !currentIs(tok!"comment", false))
            {
                write(" ");
            }
        }
        regenLineBreakHintsIfNecessary(index - 1);
    }

    void regenLineBreakHints(immutable size_t i)
    {
        immutable size_t j = expressionEndIndex(i);
        linebreakHints = chooseLineBreakTokens(i, tokens[i .. j], depths[i .. j],
            config, currentLineLength, indentLevel);
    }

    void regenLineBreakHintsIfNecessary(immutable size_t i)
    {
        if (linebreakHints.length == 0 || linebreakHints[$ - 1] <= i - 1)
            regenLineBreakHints(i);
    }

    size_t expressionEndIndex(size_t i) const pure @safe @nogc
    {
        immutable bool braces = i < tokens.length && tokens[i].type == tok!"{";
        immutable d = depths[i];
        while (true)
        {
            if (i >= tokens.length)
                break;
            if (depths[i] < d)
                break;
            if (!braces && tokens[i].type == tok!";")
                break;
            i++;
        }
        return i;
    }

    void writeParens(bool spaceAfter)
    in
    {
        assert(currentIs(tok!"("), str(current.type));
    }
    body
    {
        immutable int depth = parenDepth;
        do
        {
            formatStep();
            spaceAfterParens = spaceAfter;
        }
        while (index < tokens.length && parenDepth > depth);
    }

    bool peekIsKeyword()
    {
        return index + 1 < tokens.length && isKeyword(tokens[index + 1].type);
    }

    bool peekIsBasicType()
    {
        return index + 1 < tokens.length && isBasicType(tokens[index + 1].type);
    }

    bool peekIsLabel()
    {
        return peekIs(tok!"identifier") && peek2Is(tok!":");
    }

    int currentTokenLength() pure @safe @nogc
    {
        return tokenLength(tokens[index]);
    }

    int nextTokenLength() pure @safe @nogc
    {
        immutable size_t i = index + 1;
        if (i >= tokens.length)
            return INVALID_TOKEN_LENGTH;
        return tokenLength(tokens[i]);
    }

    ref current() const @property in
    {
        assert(index < tokens.length);
    }
    body
    {
        return tokens[index];
    }

    const(Token) peekBack()
    {
        assert(index > 0);
        return tokens[index - 1];
    }

    bool peekBackIsLiteralOrIdent()
    {
        if (index == 0)
            return false;
        switch (tokens[index - 1].type)
        {
        case tok!"doubleLiteral":
        case tok!"floatLiteral":
        case tok!"idoubleLiteral":
        case tok!"ifloatLiteral":
        case tok!"intLiteral":
        case tok!"longLiteral":
        case tok!"realLiteral":
        case tok!"irealLiteral":
        case tok!"uintLiteral":
        case tok!"ulongLiteral":
        case tok!"characterLiteral":
        case tok!"identifier":
        case tok!"stringLiteral":
        case tok!"wstringLiteral":
        case tok!"dstringLiteral":
            return true;
        default:
            return false;
        }
    }

    bool peekIsLiteralOrIdent()
    {
        if (index + 1 >= tokens.length)
            return false;
        switch (tokens[index + 1].type)
        {
        case tok!"doubleLiteral":
        case tok!"floatLiteral":
        case tok!"idoubleLiteral":
        case tok!"ifloatLiteral":
        case tok!"intLiteral":
        case tok!"longLiteral":
        case tok!"realLiteral":
        case tok!"irealLiteral":
        case tok!"uintLiteral":
        case tok!"ulongLiteral":
        case tok!"characterLiteral":
        case tok!"identifier":
        case tok!"stringLiteral":
        case tok!"wstringLiteral":
        case tok!"dstringLiteral":
            return true;
        default:
            return false;
        }
    }

    bool peekBackIs(IdType tokenType, bool ignoreComments = false)
    {
        return peekImplementation(tokenType, -1, ignoreComments);
    }

    bool peekBack2Is(IdType tokenType, bool ignoreComments = false)
    {
        return peekImplementation(tokenType, -2, ignoreComments);
    }

    bool peekImplementation(IdType tokenType, int n, bool ignoreComments = true)
    {
        auto i = index + n;
        if (ignoreComments)
            while (n != 0 && i < tokens.length && tokens[i].type == tok!"comment")
                i = n > 0 ? i + 1 : i - 1;
        return i < tokens.length && tokens[i].type == tokenType;
    }

    bool peek2Is(IdType tokenType, bool ignoreComments = true)
    {
        return peekImplementation(tokenType, 2, ignoreComments);
    }

    bool peekIsOperator()
    {
        return index + 1 < tokens.length && isOperator(tokens[index + 1].type);
    }

    bool peekIs(IdType tokenType, bool ignoreComments = true)
    {
        return peekImplementation(tokenType, 1, ignoreComments);
    }

    bool peekBackIsSlashSlash()
    {
        return index > 0 && tokens[index - 1].type == tok!"comment"
            && tokens[index - 1].text[0 .. 2] == "//";
    }

    bool currentIs(IdType tokenType, bool ignoreComments = false)
    {
        return peekImplementation(tokenType, 0, ignoreComments);
    }

    /// Bugs: not unicode correct
    size_t tokenEndLine(const Token t)
    {
        import std.algorithm : count;

        switch (t.type)
        {
        case tok!"comment":
        case tok!"stringLiteral":
        case tok!"wstringLiteral":
        case tok!"dstringLiteral":
            return t.line + (cast(ubyte[]) t.text).count('\n');
        default:
            return t.line;
        }
    }

    bool isBlockHeader(int i = 0)
    {
        if (i + index < 0 || i + index >= tokens.length)
            return false;
        auto t = tokens[i + index].type;
        return t == tok!"for" || t == tok!"foreach" || t == tok!"foreach_reverse"
            || t == tok!"while" || t == tok!"if" || t == tok!"out"
            || t == tok!"catch" || t == tok!"with";
    }

    void newline()
    {
        import std.range : assumeSorted;
        import std.algorithm : max;

        if (currentIs(tok!"comment") && index > 0 && current.line == tokenEndLine(tokens[index - 1]))
            return;

        immutable bool hasCurrent = index + 1 < tokens.length;

        if (niBraceDepth > 0 && !peekBackIsSlashSlash() && hasCurrent
                && tokens[index].type == tok!"}" && !assumeSorted(
                astInformation.funLitEndLocations).equalRange(tokens[index].index).empty)
        {
            write(" ");
            return;
        }

        output.put("\n");

        if (!justAddedExtraNewline && index > 0 && hasCurrent
                && tokens[index].line - tokenEndLine(tokens[index - 1]) > 1)
        {
            output.put("\n");
        }

        justAddedExtraNewline = false;
        currentLineLength = 0;

        if (hasCurrent)
        {
            bool switchLabel = false;
            if (currentIs(tok!"else"))
            {
                auto i = indents.indentToMostRecent(tok!"if");
                auto v = indents.indentToMostRecent(tok!"version");
                auto mostRecent = max(i, v);
                if (mostRecent != -1)
                    indentLevel = mostRecent;
            }
            else if (currentIs(tok!"identifier") && peekIs(tok!":"))
            {
                while ((peekBackIs(tok!"}", true) || peekBackIs(tok!";", true))
                        && indents.length && isTempIndent(indents.top()))
                {
                    indents.pop();
                }
                auto l = indents.indentToMostRecent(tok!"switch");
                if (l != -1)
                {
                    indentLevel = l;
                    switchLabel = true;
                }
                else if (!isBlockHeader(2) || peek2Is(tok!"if"))
                {
                    auto l2 = indents.indentToMostRecent(tok!"{");
                    indentLevel = l2 == -1 ? indentLevel : l2;
                }
                else
                    indentLevel = indents.indentSize;
            }
            else if (currentIs(tok!"case") || currentIs(tok!"default"))
            {
                while ((peekBackIs(tok!"}", true) || peekBackIs(tok!";", true))
                        && indents.length && isTempIndent(indents.top()))
                {
                    indents.pop();
                }
                auto l = indents.indentToMostRecent(tok!"switch");
                if (l != -1)
                    indentLevel = l;
            }
            else if (currentIs(tok!"{")
                    && !astInformation.structInitStartLocations.canFindIndex(tokens[index].index)
                    && !astInformation.funLitStartLocations.canFindIndex(tokens[index].index))
            {
                while (indents.length && isWrapIndent(indents.top))
                    indents.pop();
                indents.push(tok!"{");
                if (index == 1 || peekBackIs(tok!":", true) || peekBackIs(tok!"{",
                        true) || peekBackIs(tok!"}", true) || peekBackIs(tok!")",
                        true) || peekBackIs(tok!";", true))
                {
                    indentLevel = indents.indentSize - 1;
                }
            }
            else if (currentIs(tok!"}"))
            {
                while (indents.length && isTempIndent(indents.top()))
                    indents.pop();
                if (indents.top == tok!"{")
                {
                    indentLevel = indents.indentToMostRecent(tok!"{");
                    indents.pop();
                }
                while (indents.length && isTempIndent(indents.top)
                        && ((indents.top != tok!"if"
                        && indents.top != tok!"version") || !peekIs(tok!"else")))
                {
                    indents.pop();
                }
            }
            else if (currentIs(tok!"]"))
            {
                while (indents.length && isWrapIndent(indents.top))
                    indents.pop();
                if (indents.length && indents.top == tok!"]")
                {
                    indents.pop();
                    indentLevel = indents.indentSize;
                }
            }
            else if (astInformation.attributeDeclarationLines.canFindIndex(current.line))
            {
                auto l = indents.indentToMostRecent(tok!"{");
                if (l != -1)
                    indentLevel = l;
            }
            else
            {
                while (indents.length && (peekBackIs(tok!"}", true)
                        || (peekBackIs(tok!";", true) && indents.top != tok!";"))
                        && isTempIndent(indents.top()))
                {
                    indents.pop();
                }
                indentLevel = indents.indentSize;
            }
            indent();
        }
    }

    void write(string str)
    {
        currentLineLength += str.length;
        output.put(str);
    }

    void writeToken()
    {
        if (current.text is null)
        {
            auto s = str(current.type);
            currentLineLength += s.length;
            output.put(str(current.type));
        }
        else
        {
            // You know what's awesome? Windows can't handle its own line
            // endings correctly.
            version (Windows)
                output.put(current.text.replace("\r", ""));
            else
                output.put(current.text);
            currentLineLength += current.text.length;
        }
        index++;
    }

    void indent()
    {
        if (config.useTabs)
            foreach (i; 0 .. indentLevel)
            {
                currentLineLength += config.tabSize;
                output.put("\t");
            }
        else
            foreach (i; 0 .. indentLevel)
                foreach (j; 0 .. config.indentSize)
                {
                    output.put(" ");
                    currentLineLength++;
                }
    }

    void pushWrapIndent(IdType type = tok!"")
    {
        immutable t = type == tok!"" ? tokens[index].type : type;
        if (parenDepth == 0)
        {
            if (indents.wrapIndents == 0)
                indents.push(t);
        }
        else if (indents.wrapIndents < 1)
            indents.push(t);
    }

    int indentLevel;

    /// Current index into the tokens array
    size_t index;

    /// Length of the current line (so far)
    uint currentLineLength = 0;

    /// Output to write output to
    OutputRange output;

    /// Tokens being formatted
    const(Token)[] tokens;

    /// Paren depth info
    immutable short[] depths;

    /// Information about the AST
    ASTInformation* astInformation;

    size_t[] linebreakHints;

    IndentStack indents;

    /// Configuration
    FormatterConfig* config;

    /// Keep track of whether or not an extra newline was just added because of
    /// an import statement.
    bool justAddedExtraNewline;

    int parenDepth;

    int sBraceDepth;

    int niBraceDepth;

    bool spaceAfterParens;
}

bool isWrapIndent(IdType type) pure nothrow @nogc @safe
{
    return type != tok!"{" && type != tok!":" && type != tok!"]" && isOperator(type);
}

bool isTempIndent(IdType type) pure nothrow @nogc @safe
{
    return type != tok!"{";
}

/// The only good brace styles
enum BraceStyle
{
    allman,
    otbs
}

/// Configuration options for formatting
struct FormatterConfig
{
    /// Number of spaces used for indentation
    uint indentSize = 4;
    /// Use tabs or spaces
    bool useTabs = false;
    /// Size of a tab character
    uint tabSize = 4;
    /// Soft line wrap limit
    uint columnSoftLimit = 80;
    /// Hard line wrap limit
    uint columnHardLimit = 120;
    /// Use the One True Brace Style
    BraceStyle braceStyle = BraceStyle.allman;
}

bool canFindIndex(const size_t[] items, size_t index)
{
    import std.range : assumeSorted;

    return !assumeSorted(items).equalRange(index).empty;
}

///
struct ASTInformation
{
    /// Sorts the arrays so that binary search will work on them
    void cleanup()
    {
        import std.algorithm : sort;

        sort(doubleNewlineLocations);
        sort(spaceAfterLocations);
        sort(unaryLocations);
        sort(attributeDeclarationLines);
        sort(caseEndLocations);
        sort(structInitStartLocations);
        sort(structInitEndLocations);
        sort(funLitStartLocations);
        sort(funLitEndLocations);
        sort(conditionalWithElseLocations);
        sort(arrayStartLocations);
    }

    /// Locations of end braces for struct bodies
    size_t[] doubleNewlineLocations;

    /// Locations of tokens where a space is needed (such as the '*' in a type)
    size_t[] spaceAfterLocations;

    /// Locations of unary operators
    size_t[] unaryLocations;

    /// Lines containing attribute declarations
    size_t[] attributeDeclarationLines;

    /// Case statement colon locations
    size_t[] caseEndLocations;

    /// Opening braces of struct initializers
    size_t[] structInitStartLocations;

    /// Closing braces of struct initializers
    size_t[] structInitEndLocations;

    /// Opening braces of function literals
    size_t[] funLitStartLocations;

    /// Closing braces of function literals
    size_t[] funLitEndLocations;

    size_t[] conditionalWithElseLocations;

    size_t[] conditionalStatementLocations;

    size_t[] arrayStartLocations;
}

/// Collects information from the AST that is useful for the formatter
final class FormatVisitor : ASTVisitor
{
    ///
    this(ASTInformation* astInformation)
    {
        this.astInformation = astInformation;
    }

    override void visit(const ArrayInitializer arrayInitializer)
    {
        astInformation.arrayStartLocations ~= arrayInitializer.startLocation;
        arrayInitializer.accept(this);
    }

    override void visit(const ConditionalDeclaration dec)
    {
        if (dec.falseDeclaration !is null)
        {
            auto condition = dec.compileCondition;
            if (condition.versionCondition !is null)
            {
                astInformation.conditionalWithElseLocations ~= condition.versionCondition.versionIndex;
            }
            else if (condition.debugCondition !is null)
            {
                astInformation.conditionalWithElseLocations ~= condition.debugCondition.debugIndex;
            }
            // Skip "static if" because the formatting for normal "if" handles
            // it properly
        }
        dec.accept(this);
    }

    override void visit(const ConditionalStatement statement)
    {
        auto condition = statement.compileCondition;
        if (condition.versionCondition !is null)
        {
            astInformation.conditionalStatementLocations ~= condition.versionCondition.versionIndex;
        }
        else if (condition.debugCondition !is null)
        {
            astInformation.conditionalStatementLocations ~= condition.debugCondition.debugIndex;
        }
        statement.accept(this);
    }

    override void visit(const FunctionLiteralExpression funcLit)
    {
        astInformation.funLitStartLocations ~= funcLit.functionBody.blockStatement.startLocation;
        astInformation.funLitEndLocations ~= funcLit.functionBody.blockStatement.endLocation;
        funcLit.accept(this);
    }

    override void visit(const DefaultStatement defaultStatement)
    {
        astInformation.caseEndLocations ~= defaultStatement.colonLocation;
        defaultStatement.accept(this);
    }

    override void visit(const CaseStatement caseStatement)
    {
        astInformation.caseEndLocations ~= caseStatement.colonLocation;
        caseStatement.accept(this);
    }

    override void visit(const CaseRangeStatement caseRangeStatement)
    {
        astInformation.caseEndLocations ~= caseRangeStatement.colonLocation;
        caseRangeStatement.accept(this);
    }

    override void visit(const FunctionBody functionBody)
    {
        if (functionBody.blockStatement !is null)
            astInformation.doubleNewlineLocations ~= functionBody.blockStatement.endLocation;
        if (functionBody.bodyStatement !is null && functionBody.bodyStatement.blockStatement !is null)
            astInformation.doubleNewlineLocations ~= functionBody.bodyStatement.blockStatement.endLocation;
        functionBody.accept(this);
    }

    override void visit(const StructInitializer structInitializer)
    {
        astInformation.structInitStartLocations ~= structInitializer.startLocation;
        astInformation.structInitEndLocations ~= structInitializer.endLocation;
        structInitializer.accept(this);
    }

    override void visit(const EnumBody enumBody)
    {
        astInformation.doubleNewlineLocations ~= enumBody.endLocation;
        enumBody.accept(this);
    }

    override void visit(const Unittest unittest_)
    {
        astInformation.doubleNewlineLocations ~= unittest_.blockStatement.endLocation;
        unittest_.accept(this);
    }

    override void visit(const Invariant invariant_)
    {
        astInformation.doubleNewlineLocations ~= invariant_.blockStatement.endLocation;
        invariant_.accept(this);
    }

    override void visit(const StructBody structBody)
    {
        astInformation.doubleNewlineLocations ~= structBody.endLocation;
        structBody.accept(this);
    }

    override void visit(const TemplateDeclaration templateDeclaration)
    {
        astInformation.doubleNewlineLocations ~= templateDeclaration.endLocation;
        templateDeclaration.accept(this);
    }

    override void visit(const TypeSuffix typeSuffix)
    {
        if (typeSuffix.star.type != tok!"")
            astInformation.spaceAfterLocations ~= typeSuffix.star.index;
        typeSuffix.accept(this);
    }

    override void visit(const UnaryExpression unary)
    {
        if (unary.prefix.type == tok!"~" || unary.prefix.type == tok!"&"
                || unary.prefix.type == tok!"*" || unary.prefix.type == tok!"+"
                || unary.prefix.type == tok!"-")
        {
            astInformation.unaryLocations ~= unary.prefix.index;
        }
        unary.accept(this);
    }

    override void visit(const AttributeDeclaration attributeDeclaration)
    {
        astInformation.attributeDeclarationLines ~= attributeDeclaration.line;
        attributeDeclaration.accept(this);
    }

private:
    ASTInformation* astInformation;
    alias visit = ASTVisitor.visit;
}

/// Length of an invalid token
enum int INVALID_TOKEN_LENGTH = -1;

string generateFixedLengthCases()
{
    import std.algorithm : map;
    import std.string : format;

    string[] spacedOperatorTokens = [
        ",", "..", "...", "/", "/=", "!", "!<", "!<=", "!<>", "!<>=", "!=", "!>",
        "!>=", "%", "%=", "&", "&&", "&=", "*", "*=", "+", "+=", "-", "-=", ":",
        ";", "<", "<<", "<<=", "<=", "<>", "<>=", "=", "==", "=>", ">", ">=",
        ">>", ">>=", ">>>", ">>>=", "?", "@", "^", "^=", "^^", "^^=", "|", "|=", "||",
        "~", "~="
    ];
    immutable spacedOperatorTokenCases = spacedOperatorTokens.map!(
        a => format(`case tok!"%s": return %d + 1;`, a, a.length)).join("\n\t");

    string[] identifierTokens = [
        "abstract", "alias", "align", "asm", "assert", "auto", "body", "bool",
        "break", "byte", "case", "cast", "catch", "cdouble", "cent", "cfloat",
        "char", "class", "const", "continue", "creal", "dchar", "debug",
        "default", "delegate", "delete", "deprecated", "do", "double", "else",
        "enum", "export", "extern", "false", "final", "finally", "float", "for",
        "foreach", "foreach_reverse", "function", "goto", "idouble", "if",
        "ifloat", "immutable", "import", "in", "inout", "int", "interface",
        "invariant", "ireal", "is", "lazy", "long", "macro", "mixin", "module",
        "new", "nothrow", "null", "out", "override", "package", "pragma",
        "private", "protected", "public", "pure", "real", "ref", "return",
        "scope", "shared", "short", "static", "struct", "super", "switch",
        "synchronized", "template", "this", "throw", "true", "try", "typedef",
        "typeid", "typeof", "ubyte", "ucent", "uint", "ulong", "union",
        "unittest", "ushort", "version", "void", "volatile", "wchar", "while",
        "with", "__DATE__", "__EOF__", "__FILE__", "__FUNCTION__", "__gshared",
        "__LINE__", "__MODULE__", "__parameters", "__PRETTY_FUNCTION__",
        "__TIME__", "__TIMESTAMP__", "__traits", "__vector", "__VENDOR__",
        "__VERSION__", "$", "++", "--", ".", "[", "]", "(", ")", "{", "}"
    ];
    immutable identifierTokenCases = identifierTokens.map!(
        a => format(`case tok!"%s": return %d;`, a, a.length)).join("\n\t");
    return spacedOperatorTokenCases ~ identifierTokenCases;
}

int tokenLength(ref const Token t) pure @safe @nogc
{
    import std.algorithm : countUntil;

    switch (t.type)
    {
    case tok!"doubleLiteral":
    case tok!"floatLiteral":
    case tok!"idoubleLiteral":
    case tok!"ifloatLiteral":
    case tok!"intLiteral":
    case tok!"longLiteral":
    case tok!"realLiteral":
    case tok!"irealLiteral":
    case tok!"uintLiteral":
    case tok!"ulongLiteral":
    case tok!"characterLiteral":
        return cast(int) t.text.length;
    case tok!"identifier":
    case tok!"stringLiteral":
    case tok!"wstringLiteral":
    case tok!"dstringLiteral":
        // TODO: Unicode line breaks and old-Mac line endings
        auto c = cast(int) t.text.countUntil('\n');
        if (c == -1)
            return cast(int) t.text.length;
        else
            return c;
        mixin(generateFixedLengthCases());
    default:
        return INVALID_TOKEN_LENGTH;
    }
}

bool isBreakToken(IdType t)
{
    switch (t)
    {
    case tok!"||":
    case tok!"&&":
    case tok!"(":
    case tok!"[":
    case tok!",":
    case tok!":":
    case tok!";":
    case tok!"^^":
    case tok!"^=":
    case tok!"^":
    case tok!"~=":
    case tok!"<<=":
    case tok!"<<":
    case tok!"<=":
    case tok!"<>=":
    case tok!"<>":
    case tok!"<":
    case tok!"==":
    case tok!"=>":
    case tok!"=":
    case tok!">=":
    case tok!">>=":
    case tok!">>>=":
    case tok!">>>":
    case tok!">>":
    case tok!">":
    case tok!"|=":
    case tok!"|":
    case tok!"-=":
    case tok!"!<=":
    case tok!"!<>=":
    case tok!"!<>":
    case tok!"!<":
    case tok!"!=":
    case tok!"!>=":
    case tok!"!>":
    case tok!"?":
    case tok!"/=":
    case tok!"/":
    case tok!"..":
    case tok!"*=":
    case tok!"&=":
    case tok!"%=":
    case tok!"%":
    case tok!"+=":
    case tok!".":
    case tok!"~":
    case tok!"+":
    case tok!"-":
        return true;
    default:
        return false;
    }
}

int breakCost(IdType t)
{
    switch (t)
    {
    case tok!"||":
    case tok!"&&":
    case tok!",":
        return 0;
    case tok!"(":
        return 60;
    case tok!"[":
        return 400;
    case tok!":":
    case tok!";":
    case tok!"^^":
    case tok!"^=":
    case tok!"^":
    case tok!"~=":
    case tok!"<<=":
    case tok!"<<":
    case tok!"<=":
    case tok!"<>=":
    case tok!"<>":
    case tok!"<":
    case tok!"==":
    case tok!"=>":
    case tok!"=":
    case tok!">=":
    case tok!">>=":
    case tok!">>>=":
    case tok!">>>":
    case tok!">>":
    case tok!">":
    case tok!"|=":
    case tok!"|":
    case tok!"-=":
    case tok!"!<=":
    case tok!"!<>=":
    case tok!"!<>":
    case tok!"!<":
    case tok!"!=":
    case tok!"!>=":
    case tok!"!>":
    case tok!"?":
    case tok!"/=":
    case tok!"/":
    case tok!"..":
    case tok!"*=":
    case tok!"&=":
    case tok!"%=":
    case tok!"%":
    case tok!"+":
    case tok!"-":
    case tok!"~":
    case tok!"+=":
        return 200;
    case tok!".":
        return 900;
    default:
        return 1000;
    }
}

unittest
{
    foreach (ubyte u; 0 .. ubyte.max)
        if (isBreakToken(u))
            assert(breakCost(u) != 1000);
}

struct State
{
    this(size_t[] breaks, const Token[] tokens, immutable short[] depths, int depth,
        const FormatterConfig* formatterConfig, int currentLineLength, int indentLevel)
    {
        import std.math : abs;

        immutable remainingCharsMultiplier = 40;
        immutable newlinePenalty = 800;

        this.breaks = breaks;
        this._depth = depth;
        import std.algorithm : map, sum;

        this._cost = 0;
        for (size_t i = 0; i != breaks.length; ++i)
        {
            immutable b = tokens[breaks[i]].type;
            immutable p = abs(depths[breaks[i]]);
            immutable bc = breakCost(b) * (p == 0 ? 1 : p * 2);
            this._cost += bc;
        }
        int ll = currentLineLength;
        size_t breakIndex = 0;
        size_t i = 0;
        this._solved = true;
        if (breaks.length == 0)
        {
            immutable int l = currentLineLength + tokens.map!(a => tokenLength(a)).sum();
            _cost = l;
            if (l > formatterConfig.columnSoftLimit)
            {
                immutable longPenalty = (l - formatterConfig.columnSoftLimit) * remainingCharsMultiplier;
                _cost += longPenalty;
                this._solved = longPenalty < newlinePenalty;
            }
            else
                this._solved = true;
        }
        else
        {
            do
            {
                immutable size_t j = breakIndex < breaks.length ? breaks[breakIndex] : tokens.length;
                ll += tokens[i .. j].map!(a => tokenLength(a)).sum();
                if (ll > formatterConfig.columnHardLimit)
                {
                    this._solved = false;
                    break;
                }
                else if (ll > formatterConfig.columnSoftLimit)
                    _cost += (ll - formatterConfig.columnSoftLimit) * remainingCharsMultiplier;
                i = j;
                ll = indentLevel * formatterConfig.indentSize;
                breakIndex++;
            }
            while (i + 1 < tokens.length);
        }
        this._cost += breaks.length * newlinePenalty;
    }

    int cost() const pure nothrow @safe @property
    {
        return _cost;
    }

    int depth() const pure nothrow @safe @property
    {
        return _depth;
    }

    int solved() const pure nothrow @safe @property
    {
        return _solved;
    }

    int opCmp(ref const State other) const pure nothrow @safe
    {
        if (cost < other.cost || (cost == other.cost && ((breaks.length
                && other.breaks.length && breaks[0] > other.breaks[0]) || (_solved && !other.solved))))
        {
            return -1;
        }
        return other.cost > _cost;
    }

    bool opEquals(ref const State other) const pure nothrow @safe
    {
        return other.breaks == breaks;
    }

    size_t toHash() const nothrow @safe
    {
        return typeid(breaks).getHash(&breaks);
    }

    size_t[] breaks;
private:
    int _cost;
    int _depth;
    bool _solved;
}

size_t[] chooseLineBreakTokens(size_t index, const Token[] tokens, immutable short[] depths,
    const FormatterConfig* formatterConfig, int currentLineLength, int indentLevel)
{
    import std.container.rbtree : RedBlackTree;
    import std.algorithm : filter, min;
    import core.memory : GC;

    enum ALGORITHMIC_COMPLEXITY_SUCKS = 25;
    immutable size_t tokensEnd = min(tokens.length, ALGORITHMIC_COMPLEXITY_SUCKS);
    int depth = 0;
    auto open = new RedBlackTree!State;
    open.insert(State(cast(size_t[])[], tokens[0 .. tokensEnd],
        depths[0 .. tokensEnd], depth, formatterConfig, currentLineLength, indentLevel));
    State lowest;
    GC.disable();
    scope(exit) GC.enable();
    while (!open.empty)
    {
        State current = open.front();
        if (current.cost < lowest.cost)
            lowest = current;
        open.removeFront();
        if (current.solved)
        {
            current.breaks[] += index;
            return current.breaks;
        }
        foreach (next; validMoves(tokens[0 .. tokensEnd], depths[0 .. tokensEnd],
                current, formatterConfig, currentLineLength, indentLevel, depth))
        {
            open.insert(next);
        }
    }
    if (open.empty)
    {
        lowest.breaks[] += index;
        return lowest.breaks;
    }
    foreach (r; open[].filter!(a => a.solved))
    {
        r.breaks[] += index;
        return r.breaks;
    }
    assert(false);
}

State[] validMoves(const Token[] tokens, immutable short[] depths, ref const State current,
    const FormatterConfig* formatterConfig, int currentLineLength, int indentLevel,
    int depth)
{
    import std.algorithm : sort, canFind;
    import std.array : insertInPlace;

    State[] states;
    foreach (i, token; tokens)
    {
        if (!isBreakToken(token.type) || current.breaks.canFind(i))
            continue;
        size_t[] breaks;
        breaks ~= current.breaks;
        breaks ~= i;
        sort(breaks);
        states ~= State(breaks, tokens, depths, depth + 1, formatterConfig,
            currentLineLength, indentLevel);
    }
    return states;
}

struct IndentStack
{
    int indentToMostRecent(IdType item)
    {
        size_t i = index;
        while (true)
        {
            if (arr[i] == item)
                return indentSize(i);
            if (i > 0)
                i--;
            else
                return -1;
        }
    }

    int wrapIndents() const pure nothrow @property
    {
        if (index == 0)
            return 0;
        int tempIndentCount = 0;
        for (size_t i = index; i > 0; i--)
        {
            if (!isWrapIndent(arr[i]) && arr[i] != tok!"]")
                break;
            tempIndentCount++;
        }
        return tempIndentCount;
    }

    void push(IdType item) pure nothrow
    {
        index = index == 255 ? index : index + 1;
        arr[index] = item;
    }

    void pop() pure nothrow
    {
        index = index == 0 ? index : index - 1;
    }

    IdType top() const pure nothrow @property
    {
        return arr[index];
    }

    int indentSize(size_t k = size_t.max) const pure nothrow
    {
        if (index == 0)
            return 0;
        immutable size_t j = k == size_t.max ? index : k - 1;
        int size = 0;
        foreach (i; 1 .. j + 1)
        {
            if ((i + 1 <= index && arr[i] != tok!"]" && !isWrapIndent(arr[i])
                    && isTempIndent(arr[i]) && (!isTempIndent(arr[i + 1])
                    || arr[i + 1] == tok!"switch")))
            {
                continue;
            }
            size++;
        }
        return size;
    }

    int length() const pure nothrow @property
    {
        return cast(int) index;
    }

private:
    size_t index;
    IdType[256] arr;
}