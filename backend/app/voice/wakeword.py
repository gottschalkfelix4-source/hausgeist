"""Aktivierungswort: Text -> Schluesselwort-Zeilen fuer den Offline-Erkenner der App (sherpa-onnx).

Das Modell auf dem Tablet (sherpa-onnx-kws-zipformer-gigaspeech-3.3M) kennt 500 englische
BPE-Silben. Hier wird ein frei gewaehltes Wort genauso zerlegt wie mit SentencePiece, damit
die App ohne eigenen Tokenizer auskommt. kws_vocab.txt: Silbe<TAB>Score, Reihenfolge = Token-ID.
"""
import re
import unicodedata
from functools import cache
from pathlib import Path

WORD = "▁"
SUGGESTIONS = ["Computer", "Alexa", "Jarvis", "Hey Hausgeist (hey house guyst)"]
MAX_WORDS = 5
# Empfindlichkeit -> Schwelle des Erkenners (0..1, kleiner = loest leichter aus)
THRESHOLDS = {"niedrig": 0.30, "mittel": 0.20, "hoch": 0.12}
_GERMAN = {"Ä": "AE", "Ö": "OE", "Ü": "UE", "ß": "SS", "ẞ": "SS"}


@cache
def vocab() -> dict[str, float]:
    lines = (Path(__file__).parent / "kws_vocab.txt").read_text(encoding="utf-8").splitlines()
    return {piece: float(score) for piece, score in (line.split("\t") for line in lines)}


def normalize(text: str) -> str:
    """Grossbuchstaben A-Z, Apostroph und Bindestrich; Umlaute ausgeschrieben, Rest weg."""
    text = "".join(_GERMAN.get(ch, ch) for ch in text.upper())
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return " ".join(re.sub(r"[^A-Z'\- ]", " ", text).split())


def _encode_word(word: str) -> list[str]:
    """Unigram wie SentencePiece: Zerlegung mit der hoechsten Summe der Silben-Scores (Viterbi)."""
    v = vocab()
    text = WORD + word
    longest = max(map(len, v))
    best: list[tuple[float, int] | None] = [(0.0, 0)] + [None] * len(text)
    for end in range(1, len(text) + 1):
        for start in range(max(0, end - longest), end):
            score = v.get(text[start:end])
            if score is None or best[start] is None:
                continue
            total = best[start][0] + score
            if best[end] is None or total > best[end][0]:
                best[end] = (total, start)
    parts, end = [], len(text)
    while end:
        start = best[end][1]
        parts.append(text[start:end])
        end = start
    return parts[::-1]


def tokens(text: str) -> list[str]:
    return [t for word in normalize(text).split() for t in _encode_word(word)]


def parse_words(value: str) -> list[tuple[str, str]]:
    """"Computer, Hey Hausgeist (hey house guyst)" -> [(Anzeige, Aussprache), ...].

    In Klammern steht optional, wie das Wort fuer ein englisches Ohr klingt; das hilft dem
    englischen Modell bei deutschen Woertern. Leere und doppelte Eintraege fallen weg.
    """
    seen, out = set(), []
    for part in value.split(","):
        m = re.fullmatch(r"\s*([^()]*?)\s*(?:\(([^()]*)\))?\s*", part)
        if not m:
            continue
        name = " ".join(m[1].split())
        spoken = normalize(m[2] or "") or normalize(name)
        if name and spoken and spoken not in seen:
            seen.add(spoken)
            out.append((name, spoken))
    return out[:MAX_WORDS]


def keywords(value: str, sensitivity: str) -> str:
    """Eine Zeile je Wort: Silben, Schwelle und Anzeigename (ohne Leerzeichen)."""
    threshold = THRESHOLDS.get(sensitivity, THRESHOLDS["mittel"])
    lines = [f"{' '.join(tokens(spoken))} #{threshold} @{name.replace(' ', '_')}"
             for name, spoken in parse_words(value)]
    return "\n".join(lines)
