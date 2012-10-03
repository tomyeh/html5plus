/**
 * This library contains extra APIs that aren't in the DOM, but are useful
 * when interacting with the parse tree. For example, [SourceSpan] and
 * [TreeVisitor].
 */
library dom_parsing;

import 'dart:math';
import 'dart:utf' as utf; // show codepointsToString
import 'dom.dart';
import 'src/constants.dart' as constants; // show NEWLINE


/**
 * A simple class that tracks span positions.
 */
class SourceSpan implements Comparable {
  final SourceFileInfo file;

  /** The start offset of this span. 0-based. */
  final int start;

  /** The end offset of this span, exclusive. 0-based. */
  final int end;

  /** The length of this span, in characters. */
  int get length => end - start;

  SourceSpan(this.file, this.start, this.end) {
    _checkRange();
  }

  /**
   * Creates a new source span that is the union of two existing spans [start]
   * and [end]. Note that the resulting span might contain some positions that
   * were not in either of the original spans if [start] and [end] are disjoint.
   */
  SourceSpan.union(SourceSpan start, SourceSpan end)
      : file = start.file, start = start.start, end = end.end {
    if (start.file != end.file) {
      throw new ArgumentError('start and end must be from the same file');
    }
    _checkRange();
  }

  void _checkRange() {
    if (start < 0) throw new ArgumentError('start $start must be >= 0');
    if (end < start) {
      throw new ArgumentError('end $end must be >= start $start');
    }
  }

  String toMessageString(String filename, String message,
        [bool includeText = true, bool useColors = false]) {
    return file.getLocationMessage(filename, message, start, end, includeText,
        useColors);
  }

  /** The 0-based line in the file where this span starts. */
  int get line => file.getLine(start);

  /** The 0-based column in the file where this span starts. */
  int get column => file.getColumn(line, start);

  /**
   * The 0-based line in the file where this span ends, inclusive.
   * So if this span is contained in a single line, this will equal [line].
   */
  int get endLine => file.getLine(end);

  /** The 0-based column in the file where this span ends, exclusive. */
  int get endColumn => file.getColumn(endLine, end);

  /** The source text for this span, if available. */
  String get sourceText => file.getText(start, end);

  /**
   * Compares two source spans. If the spans are not in the same file, this
   * method generates an error.
   */
  int compareTo(SourceSpan other) {
    if (file != other.file) {
      throw new ArgumentError('can only compare spans of the same file');
    }
    int d = start - other.start;
    return d == 0 ? (end - other.end) : d;
  }

  /**
   * Gets the location in standard printed form `filename:line:column`, where
   * [line] and [column] are adjusted by 1 to match the convention in editors.
   */
  String getLocationText(String filename) {
    var line = file.getLine(start);
    var column = file.getColumn(line, start);
    return '$filename:${line + 1}:${column + 1}';
  }

  String getLocationMessage(String filename, String message,
    [bool includeText = true, bool useColors = false]) {
    return file.getLocationMessage(filename, message, start, end,
        includeText, useColors);
  }
}


/**
 * Stores information about a source file, to permit computation of the line
 * and column. Also contains a nice default error message highlighting the
 * code location.
 */
// TODO(jmesserly): this type fits in strangely. It might make sense to make
// this a more fully featured file abstraction.
class SourceFileInfo {
  final List<int> _lineStarts;
  final List<int> _decodedChars;

  SourceFileInfo(this._lineStarts, this._decodedChars);

  /** Gets the 0-based line in the file for this offset. */
  int getLine(int offset) {
    // TODO(jmesserly): Dart needs a binary search function we can use here.
    for (int i = 0; i < _lineStarts.length; i++) {
      if (_lineStarts[i] > offset) return i - 1;
    }
    return _lineStarts.length - 1;
  }

  /** Gets the 0-based column in the file for this offset. */
  int getColumn(int line, int offset) {
    return offset - _lineStarts[line];
  }

  /** Gets the text at the given offsets. */
  String getText(int start, [int end]) {
    if (_decodedChars == null) {
      throw new UnsupportedOperationException('getText is only supported '
          'if parser.generateSpans is true.');
    }

    return utf.codepointsToString(_decodedChars.getRange(start, end - start));
  }

  /**
   * Create a pretty string representation from a character position
   * in the file.
   */
  String getLocationMessage(String filename, String message, int start,
      [int end, bool includeText = true, bool useColors = false]) {

    // Color constants used for generating messages.
    // TODO(jmesserly): it would be more useful to pass in an object that
    // controls how the errors are printed. This method is a bit too smart.
    final String RED_COLOR = '\u001b[31m';
    final String NO_COLOR = '\u001b[0m';

    var line = getLine(start);
    var column = getColumn(line, start);

    var msg = '$filename:${line + 1}:${column + 1}: $message';
    if (!includeText) return msg;

    if (_decodedChars == null) {
      throw new UnsupportedOperationException('includeText is only supported '
          'if parser.generateSpans is true.');
    }

    var buf = new StringBuffer(msg);
    buf.add('\n');
    var textLine;

    // +1 for 0-indexing, +1 again to avoid the last line of the file
    if ((line + 2) < _lineStarts.length) {
      textLine = getText(_lineStarts[line], _lineStarts[line + 1]);
    } else {
      textLine = getText(_lineStarts[line]);
      textLine = '${textLine}\n';
    }

    int toColumn = min(column + (end-start), textLine.length);
    if (useColors) {
      buf.add(textLine.substring(0, column));
      buf.add(RED_COLOR);
      buf.add(textLine.substring(column, toColumn));
      buf.add(NO_COLOR);
      buf.add(textLine.substring(toColumn));
    } else {
      buf.add(textLine);
    }

    int i = 0;
    for (; i < column; i++) {
      buf.add(' ');
    }

    if (useColors) buf.add(RED_COLOR);
    for (; i < toColumn; i++) {
      buf.add('^');
    }
    if (useColors) buf.add(NO_COLOR);
    return buf.toString();
  }
}


/** A simple tree visitor for the DOM nodes. */
class TreeVisitor {
  visit(Node node) {
    switch (node.nodeType) {
      case Node.ELEMENT_NODE: return visitElement(node);
      case Node.TEXT_NODE: return visitText(node);
      case Node.COMMENT_NODE: return visitComment(node);
      case Node.DOCUMENT_FRAGMENT_NODE: return visitDocumentFragment(node);
      case Node.DOCUMENT_NODE: return visitDocument(node);
      case Node.DOCUMENT_TYPE_NODE: return visitDocumentType(node);
      default: throw new UnsupportedOperationException(
          'DOM node type ${node.nodeType}');
    }
  }

  visitChildren(Node node) {
    for (var child in node.nodes) visit(child);
  }

  /**
   * The fallback handler if the more specific visit method hasn't been
   * overriden. Only use this from a subclass of [TreeVisitor], otherwise
   * call [visit] instead.
   */
  visitNodeFallback(Node node) => visitChildren(node);

  visitDocument(Document node) => visitNodeFallback(node);

  visitDocumentType(DocumentType node) => visitNodeFallback(node);

  visitText(Text node) => visitNodeFallback(node);

  // TODO(jmesserly): visit attributes.
  visitElement(Element node) => visitNodeFallback(node);

  visitComment(Comment node) => visitNodeFallback(node);

  // Note: visits document by default because DocumentFragment is a Document.
  visitDocumentFragment(DocumentFragment node) => visitDocument(node);
}

/**
 * Converts the DOM tree into an HTML string with code markup suitable for
 * displaying the HTML's source code with CSS colors for different parts of the
 * markup. See also [CodeMarkupVisitor].
 */
String htmlToCodeMarkup(Node node) {
  return (new CodeMarkupVisitor()..visit(node)).toString();
}

/**
 * Converts the DOM tree into an HTML string with code markup suitable for
 * displaying the HTML's source code with CSS colors for different parts of the
 * markup. See also [htmlToCodeMarkup].
 */
class CodeMarkupVisitor extends TreeVisitor {
  final StringBuffer _str;

  CodeMarkupVisitor() : _str = new StringBuffer();

  String toString() => _str.toString();

  visitDocument(Document node) {
    _str.add("<pre>");
    visitChildren(node);
    _str.add("</pre>");
  }

  visitDocumentType(DocumentType node) {
    _str.add('<code class="markup doctype">&lt;!DOCTYPE ${node.tagName}>'
        '</code>');
  }

  visitText(Text node) {
    // TODO(jmesserly): would be nice to use _addOuterHtml directly.
    _str.add(node.outerHTML);
  }

  visitElement(Element node) {
    _str.add('&lt;<code class="markup element-name">${node.tagName}</code>');
    if (node.attributes.length > 0) {
      node.attributes.forEach((key, v) {
        v = htmlEscapeMinimal(v, {'"': "&quot;"});
        _str.add(' <code class="markup attribute-name">$key</code>'
            '=<code class="markup attribute-value">"$v"</code>');
      });
    }
    if (node.nodes.length > 0) {
      _str.add(">");
      visitChildren(node);
    } else if (isVoidElement(node.tagName)) {
      _str.add(">");
      return;
    }
    _str.add('&lt;/<code class="markup element-name">${node.tagName}</code>>');
  }

  visitComment(Comment node) {
    var data = htmlEscapeMinimal(node.data);
    _str.add('<code class="markup comment">&lt;!--${data}--></code>');
  }
}


/**
 * Note: this is meant to match:
 * <http://docs.python.org/library/xml.sax.utils.html#xml.sax.saxutils.escape>
 * So we only escape `&` `<` and `>`, unlike Dart's htmlEscape function.
 */
String htmlEscapeMinimal(String text, [Map extraReplace]) {
  // TODO(efortuna): A more efficient implementation.
  text = text.replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;");
  if (extraReplace != null) {
    extraReplace.forEach((k, v) { text = text.replaceAll(k, v); });
  }
  return text;
}


/**
 * Returns true if this tag name is a void element.
 * This method is useful to a pretty printer, because void elements must not
 * have an end tag.
 * See <http://dev.w3.org/html5/markup/syntax.html#void-elements> for more info.
 */
bool isVoidElement(String tagName) {
  switch (tagName) {
    case "area": case "base": case "br": case "col": case "command":
    case "embed": case "hr": case "img": case "input": case "keygen":
    case "link": case "meta": case "param": case "source": case "track":
    case "wbr":
      return true;
  }
  return false;
}