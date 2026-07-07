/// A single sung word within a word-by-word ([LyricLine.words]) line.
class LyricWord {
  final String text;
  final Duration start;
  final Duration end;

  const LyricWord({required this.text, required this.start, required this.end});

  Duration get duration => end - start;
}

/// A lyric line. [words] is non-empty only for word-by-word (klyric) lyrics.
class LyricLine {
  final Duration start;
  final Duration end;
  final String text;
  final List<LyricWord> words;
  final String? translation;
  final bool isBackground;

  const LyricLine({
    required this.start,
    required this.end,
    required this.text,
    this.words = const <LyricWord>[],
    this.translation,
    this.isBackground = false,
  });

  bool get isWordByWord => words.isNotEmpty;
}

/// Parsed lyrics. Build with [Lyrics.parse] from the raw `lrc` / `tlyric` /
/// `klyric` strings returned by `/weapi/song/lyric`.
class Lyrics {
  final List<LyricLine> lines;
  final bool hasWordByWord;
  final bool hasTranslation;

  const Lyrics({
    this.lines = const <LyricLine>[],
    this.hasWordByWord = false,
    this.hasTranslation = false,
  });

  static const Lyrics empty = Lyrics();

  factory Lyrics.parse({String? lrc, String? tlyric, String? klyric}) {
    List<LyricLine> lines = <LyricLine>[];
    bool wordByWord = false;

    if (klyric != null && klyric.trim().isNotEmpty) {
      lines = _parseKlyric(klyric);
      wordByWord = lines.any((l) => l.words.isNotEmpty);
    }
    if (lines.isEmpty && lrc != null && lrc.trim().isNotEmpty) {
      lines = _parseLrc(lrc);
    }
    if (lines.isEmpty) return Lyrics.empty;

    bool hasTrans = false;
    if (tlyric != null && tlyric.trim().isNotEmpty) {
      final Map<int, String> trans = _parseLrcMap(tlyric);
      if (trans.isNotEmpty) {
        lines = _attachTranslations(lines, trans);
        hasTrans = lines.any((l) => (l.translation ?? '').isNotEmpty);
      }
    }

    lines = _fillEnds(lines);
    return Lyrics(
      lines: lines,
      hasWordByWord: wordByWord,
      hasTranslation: hasTrans,
    );
  }

  /// Index of the active line at [position] (last line whose start <= position),
  /// or -1 before the first line.
  int indexAt(Duration position) {
    int idx = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].start <= position) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
}

// --- parsing helpers -------------------------------------------------------

final RegExp _timeTag =
    RegExp(r'\[(\d+):(\d+)(?:[.:](\d+))?\]');
final RegExp _msTag = RegExp(r'\[(\d+),(\d+)\]');
final RegExp _wordTok =
    RegExp(r'[(<](\d+),(\d+)(?:,\d+)?[)>]([^(<\r\n]*)');

Duration _fromTag(Match m) {
  final int min = int.parse(m.group(1)!);
  final int sec = int.parse(m.group(2)!);
  final String frac = m.group(3) ?? '0';
  int ms;
  if (frac.length >= 3) {
    ms = int.parse(frac.substring(0, 3));
  } else if (frac.length == 2) {
    ms = int.parse(frac) * 10;
  } else {
    ms = int.parse(frac) * 100;
  }
  return Duration(minutes: min, seconds: sec, milliseconds: ms);
}

List<LyricLine> _parseLrc(String raw) {
  final List<LyricLine> out = <LyricLine>[];
  for (final String line in raw.split(RegExp(r'\r?\n'))) {
    final Iterable<Match> tags = _timeTag.allMatches(line);
    if (tags.isEmpty) continue;
    final String text = line.replaceAll(_timeTag, '').trim();
    if (text.isEmpty) continue;
    for (final Match t in tags) {
      final Duration start = _fromTag(t);
      out.add(LyricLine(start: start, end: start, text: text));
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

Map<int, String> _parseLrcMap(String raw) {
  final Map<int, String> out = <int, String>{};
  for (final String line in raw.split(RegExp(r'\r?\n'))) {
    final Iterable<Match> tags = _timeTag.allMatches(line);
    if (tags.isEmpty) continue;
    final String text = line.replaceAll(_timeTag, '').trim();
    if (text.isEmpty) continue;
    for (final Match t in tags) {
      out[_fromTag(t).inMilliseconds] = text;
    }
  }
  return out;
}

List<LyricLine> _parseKlyric(String raw) {
  final List<LyricLine> out = <LyricLine>[];
  for (final String line in raw.split(RegExp(r'\r?\n'))) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    // Line header: either [mm:ss.xxx] or [startMs,durMs].
    Duration? lineStart;
    final Match? ms = _msTag.matchAsPrefix(trimmed);
    final Match? tag = _timeTag.matchAsPrefix(trimmed);
    int headerEnd = 0;
    if (ms != null) {
      lineStart = Duration(milliseconds: int.parse(ms.group(1)!));
      headerEnd = ms.end;
    } else if (tag != null) {
      lineStart = _fromTag(tag);
      headerEnd = tag.end;
    }
    if (lineStart == null) continue;

    final String body = trimmed.substring(headerEnd);
    final List<LyricWord> words = <LyricWord>[];
    final StringBuffer textBuf = StringBuffer();
    final int lineStartMs = lineStart.inMilliseconds;
    for (final Match w in _wordTok.allMatches(body)) {
      final int offset = int.parse(w.group(1)!);
      final int dur = int.parse(w.group(2)!);
      final String text = w.group(3) ?? '';
      if (text.isEmpty) continue;
      // Offsets are absolute when they already exceed the line start; otherwise
      // they are relative to the line start.
      final int startMs =
          (lineStartMs > 0 && offset >= lineStartMs) ? offset : lineStartMs + offset;
      words.add(LyricWord(
        text: text,
        start: Duration(milliseconds: startMs),
        end: Duration(milliseconds: startMs + dur),
      ));
      textBuf.write(text);
    }

    if (words.isEmpty) {
      final String plain = body.replaceAll(_wordTok, '').trim();
      if (plain.isEmpty) continue;
      out.add(LyricLine(start: lineStart, end: lineStart, text: plain));
    } else {
      out.add(LyricLine(
        start: lineStart,
        end: words.last.end,
        text: textBuf.toString().trim(),
        words: words,
      ));
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

List<LyricLine> _attachTranslations(
    List<LyricLine> lines, Map<int, String> trans) {
  return <LyricLine>[
    for (final LyricLine l in lines)
      LyricLine(
        start: l.start,
        end: l.end,
        text: l.text,
        words: l.words,
        translation: _nearestTranslation(l.start.inMilliseconds, trans),
        isBackground: l.isBackground,
      ),
  ];
}

String? _nearestTranslation(int ms, Map<int, String> trans) {
  final String? exact = trans[ms];
  if (exact != null) return exact;
  int bestKey = -1;
  int bestDelta = 1 << 30;
  for (final int k in trans.keys) {
    final int d = (k - ms).abs();
    if (d < bestDelta) {
      bestDelta = d;
      bestKey = k;
    }
  }
  if (bestKey >= 0 && bestDelta <= 400) return trans[bestKey];
  return null;
}

List<LyricLine> _fillEnds(List<LyricLine> lines) {
  if (lines.isEmpty) return lines;
  final List<LyricLine> out = <LyricLine>[];
  for (int i = 0; i < lines.length; i++) {
    final LyricLine l = lines[i];
    Duration end = l.end;
    if (end <= l.start) {
      end = i + 1 < lines.length
          ? lines[i + 1].start
          : l.start + const Duration(seconds: 4);
    }
    out.add(LyricLine(
      start: l.start,
      end: end,
      text: l.text,
      words: l.words,
      translation: l.translation,
      isBackground: l.isBackground,
    ));
  }
  return out;
}
