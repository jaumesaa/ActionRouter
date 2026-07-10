#!/usr/bin/env python3
"""Build reproducible routing-episode suites for the ActionRouter benchmark.

Sources (downloaded into --cache beforehand, see README.md):
  - CLINC-150 (data_full.json)         CC-BY-3.0   in-scope + out-of-scope
  - Banking77 (train/test csv)         CC-BY-4.0   many near-identical intents
  - MASSIVE 1.1 (per-locale jsonl)     CC-BY-4.0   51-language parallel utterances

An *episode* is one routing decision: a query, the subset of actions
available at that moment, and the expected outcome (an action id, or null
meaning the router should abstain). Actions are built from dataset intents:
name/keywords from the intent slug, usage examples sampled from TRAIN
utterances only. Dev queries come from validation splits, test queries from
test splits, so calibration data (dev) never overlaps the frozen test set.

Everything is seeded and iteration orders are sorted: same seed, same output.

Usage:
  python3 build_episodes.py [--cache CACHE] [--output ../../Benchmarks/episodes] [--seed 42]
"""

import argparse
import csv
import json
import pathlib
import random
import re
from collections import Counter, defaultdict

# --- Suite size knobs (per split) -------------------------------------------
CLINC_INSCOPE = {"dev": 300, "test": 600}
CLINC_OOS = {"dev": 150, "test": 300}
CLINC_ABSENT = {"dev": 150, "test": 300}
CLINC_SCALING_QUERIES = 150          # test only; repeated at each size
CLINC_SCALING_SIZES = [5, 10, 25, 50, 100, 150]
BANKING_SIMILAR = {"dev": 200, "test": 400}
MASSIVE_PER_LANGUAGE = {"dev": 50, "test": 100}
MASSIVE_LANGUAGES = {
    "en-US": "en", "es-ES": "es", "ca-ES": "ca", "fr-FR": "fr",
    "de-DE": "de", "it-IT": "it", "pt-PT": "pt", "zh-CN": "zh",
}
PERTURBED = {"dev": 150, "test": 300}   # typo/prefix variants of CLINC in-scope
EXAMPLES_PER_ACTION = 4
DEFAULT_SET_SIZE = 25
BANKING_SET_SIZE = 10
MASSIVE_SET_SIZE = 20

QWERTY_NEIGHBOURS = {
    "q": "wa", "w": "qes", "e": "wrd", "r": "etf", "t": "ryg", "y": "tuh",
    "u": "yij", "i": "uok", "o": "ipl", "p": "ol", "a": "qsz", "s": "awdx",
    "d": "sefc", "f": "drgv", "g": "fthb", "h": "gyjn", "j": "hukm",
    "k": "jil", "l": "kop", "z": "asx", "x": "zsdc", "c": "xdfv",
    "v": "cfgb", "b": "vghn", "n": "bhjm", "m": "njk",
}


def slug_words(slug: str) -> list[str]:
    return [w for w in re.split(r"[_\-.]+", slug) if w]


def make_action(intent_id: str, slug: str, domain: str, examples: list[str],
                description_template: str) -> dict:
    words = slug_words(slug)
    return {
        "id": intent_id,
        "name": " ".join(words).capitalize(),
        "description": description_template.format(words=" ".join(words), domain=domain),
        "keywords": sorted(set(words)),
        "examples": examples,
    }


def intent_token_profiles(train_by_intent: dict[str, list[str]]) -> dict[str, set]:
    """Most-frequent content tokens per intent, for model-free hard-distractor
    selection via Jaccard similarity."""
    profiles = {}
    for intent, utterances in sorted(train_by_intent.items()):
        counter = Counter()
        for utterance in utterances:
            counter.update(t for t in re.findall(r"[a-z0-9]+", utterance.lower())
                           if len(t) > 2)
        profiles[intent] = {t for t, _ in counter.most_common(30)}
    return profiles


def hard_distractors(profiles: dict[str, set]) -> dict[str, list[str]]:
    """For each intent, other intents ranked by token-profile similarity."""
    ranked = {}
    intents = sorted(profiles)
    for intent in intents:
        mine = profiles[intent]
        scored = []
        for other in intents:
            if other == intent:
                continue
            theirs = profiles[other]
            union = len(mine | theirs) or 1
            scored.append((len(mine & theirs) / union, other))
        scored.sort(key=lambda pair: (-pair[0], pair[1]))
        ranked[intent] = [other for _, other in scored]
    return ranked


def pick_action_set(rng, gold: str, all_intents: list[str],
                    ranked_distractors: dict[str, list[str]], size: int) -> list[str]:
    """Gold + half hard distractors + half random, shuffled."""
    hard_count = (size - 1) // 2
    hard = ranked_distractors[gold][:hard_count]
    remaining = [i for i in all_intents if i != gold and i not in hard]
    randoms = rng.sample(remaining, min(size - 1 - len(hard), len(remaining)))
    chosen = [gold] + hard + randoms
    rng.shuffle(chosen)
    return chosen


def inject_typos(rng, text: str) -> str:
    words = text.split()
    eligible = [i for i, w in enumerate(words) if len(w) >= 4]
    if not eligible:
        return text
    for index in rng.sample(eligible, min(len(eligible), 1 + (len(words) > 5))):
        word = list(words[index])
        pos = rng.randrange(1, len(word) - 1)
        op = rng.choice(["swap", "drop", "neighbour"])
        if op == "swap":
            word[pos], word[pos - 1] = word[pos - 1], word[pos]
        elif op == "drop":
            del word[pos]
        else:
            char = word[pos].lower()
            if char in QWERTY_NEIGHBOURS:
                word[pos] = rng.choice(QWERTY_NEIGHBOURS[char])
        words[index] = "".join(word)
    return " ".join(words)


def prefix_of(text: str) -> str:
    cut = max(4, int(len(text) * 0.6))
    return text[:cut].rstrip()


def write_suite(output_dir: pathlib.Path, split: str, name: str, source: str,
                license_: str, seed: int, actions: dict[str, dict],
                episodes: list[dict]) -> None:
    used = sorted({aid for e in episodes for aid in e["actions"]})
    payload = {
        "suite": f"{name}-{split}",
        "source": source,
        "license": license_,
        "seed": seed,
        "actions": [actions[aid] for aid in used],
        "episodes": episodes,
    }
    path = output_dir / split / f"{name}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=1))
    print(f"wrote {path} ({len(episodes)} episodes, {len(used)} actions)")


# --- CLINC-150 ----------------------------------------------------------------

def load_clinc(cache: pathlib.Path):
    data = json.loads((cache / "clinc-data_full.json").read_text())
    def by_intent(rows):
        grouped = defaultdict(list)
        for text, intent in rows:
            grouped[intent].append(text)
        return dict(grouped)
    return {
        "train": by_intent(data["train"]),
        "dev": by_intent(data["val"]),
        "test": by_intent(data["test"]),
        "oos": {"dev": [t for t, _ in data["oos_val"]],
                "test": [t for t, _ in data["oos_test"]]},
    }


def build_clinc(rng, cache, output):
    clinc = load_clinc(cache)
    intents = sorted(clinc["train"])
    actions = {}
    for intent in intents:
        examples = rng.sample(clinc["train"][intent],
                              min(EXAMPLES_PER_ACTION, len(clinc["train"][intent])))
        actions[intent] = make_action(
            intent, intent, "assistant", examples,
            "Assistant action that handles {words} requests.")
    ranked = hard_distractors(intent_token_profiles(clinc["train"]))

    for split in ("dev", "test"):
        pool = [(intent, utterance) for intent in intents
                for utterance in sorted(clinc[split][intent])]

        # In-scope routing with mixed hard/random distractors.
        episodes = []
        for intent, utterance in rng.sample(pool, min(CLINC_INSCOPE[split], len(pool))):
            episodes.append({
                "query": utterance,
                "actions": pick_action_set(rng, intent, intents, ranked, DEFAULT_SET_SIZE),
                "gold": intent, "language": "en", "tags": [],
            })
        write_suite(output, split, "clinc-inscope", "CLINC-150", "CC-BY-3.0",
                    rng.seed_value, actions, episodes)

        # Explicit out-of-scope: the correct behaviour is abstention.
        oos_episodes = []
        oos_pool = sorted(clinc["oos"][split])
        for utterance in rng.sample(oos_pool, min(CLINC_OOS[split], len(oos_pool))):
            available = rng.sample(intents, DEFAULT_SET_SIZE)
            oos_episodes.append({
                "query": utterance, "actions": sorted(available),
                "gold": None, "language": "en", "tags": ["oos"],
            })
        write_suite(output, split, "clinc-oos", "CLINC-150", "CC-BY-3.0",
                    rng.seed_value, actions, oos_episodes)

        # Gold intentionally absent: in-scope query, but its action is not
        # available right now (dynamic action sets) -> abstain.
        absent_episodes = []
        for intent, utterance in rng.sample(pool, min(CLINC_ABSENT[split], len(pool))):
            candidates = pick_action_set(rng, intent, intents, ranked,
                                         DEFAULT_SET_SIZE + 1)
            candidates = [c for c in candidates if c != intent][:DEFAULT_SET_SIZE]
            absent_episodes.append({
                "query": utterance, "actions": candidates,
                "gold": None, "language": "en", "tags": ["absent"],
            })
        write_suite(output, split, "clinc-absent", "CLINC-150", "CC-BY-3.0",
                    rng.seed_value, actions, absent_episodes)

        # Typo and prefix perturbations of in-scope episodes.
        for tag, transform in (("typo", lambda t: inject_typos(rng, t)),
                               ("prefix", prefix_of)):
            perturbed = []
            for intent, utterance in rng.sample(pool, min(PERTURBED[split], len(pool))):
                perturbed.append({
                    "query": transform(utterance),
                    "actions": pick_action_set(rng, intent, intents, ranked,
                                               DEFAULT_SET_SIZE),
                    "gold": intent, "language": "en", "tags": [tag],
                })
            write_suite(output, split, f"clinc-{tag}", "CLINC-150", "CC-BY-3.0",
                        rng.seed_value, actions, perturbed)

    # Scaling (test only): same queries, growing action sets.
    scaling = []
    pool = [(intent, utterance) for intent in intents
            for utterance in sorted(clinc["test"][intent])]
    base_queries = rng.sample(pool, CLINC_SCALING_QUERIES)
    for size in CLINC_SCALING_SIZES:
        for intent, utterance in base_queries:
            scaling.append({
                "query": utterance,
                "actions": pick_action_set(rng, intent, intents, ranked, size),
                "gold": intent, "language": "en", "tags": ["scaling"],
            })
    write_suite(output, "test", "clinc-scaling", "CLINC-150", "CC-BY-3.0",
                rng.seed_value, actions, scaling)


# --- Banking77 ------------------------------------------------------------------

def load_banking(cache: pathlib.Path):
    def read(path):
        grouped = defaultdict(list)
        with open(path, newline="") as handle:
            for row in csv.DictReader(handle):
                grouped[row["category"]].append(row["text"])
        return dict(grouped)
    return read(cache / "banking77-train.csv"), read(cache / "banking77-test.csv")


def build_banking(rng, cache, output):
    train, test = load_banking(cache)
    intents = sorted(train)
    actions, example_sets = {}, {}
    for intent in intents:
        examples = rng.sample(train[intent], min(EXAMPLES_PER_ACTION, len(train[intent])))
        example_sets[intent] = set(examples)
        actions[intent] = make_action(
            intent, intent, "banking", examples,
            "Banking support action for {words}.")
    ranked = hard_distractors(intent_token_profiles(train))

    for split in ("dev", "test"):
        if split == "dev":
            # Banking77 has no validation split: carve dev queries from train
            # utterances NOT used as action examples.
            pool = [(i, u) for i in intents for u in sorted(train[i])
                    if u not in example_sets[i]]
        else:
            pool = [(i, u) for i in intents for u in sorted(test[i])]
        episodes = []
        for intent, utterance in rng.sample(pool, min(BANKING_SIMILAR[split], len(pool))):
            # All distractors hard: nearest intents by token profile.
            available = [intent] + ranked[intent][:BANKING_SET_SIZE - 1]
            rng.shuffle(available)
            episodes.append({
                "query": utterance, "actions": available,
                "gold": intent, "language": "en", "tags": ["similar"],
            })
        write_suite(output, split, "banking77-similar", "Banking77", "CC-BY-4.0",
                    rng.seed_value, actions, episodes)


# --- MASSIVE --------------------------------------------------------------------

def load_massive_locale(cache: pathlib.Path, locale: str):
    grouped = {"train": defaultdict(list), "dev": defaultdict(list),
               "test": defaultdict(list)}
    with open(cache / "1.1" / "data" / f"{locale}.jsonl") as handle:
        for line in handle:
            row = json.loads(line)
            partition = {"train": "train", "dev": "dev", "test": "test"}.get(row["partition"])
            if partition:
                grouped[partition][row["intent"]].append((row["utt"], row["scenario"]))
    return grouped


def build_massive(rng, cache, output):
    english = load_massive_locale(cache, "en-US")
    intents = sorted(i for i, utterances in english["train"].items()
                     if len(utterances) >= 5)
    actions = {}
    for intent in intents:
        utterances = sorted(u for u, _ in english["train"][intent])
        scenario = english["train"][intent][0][1]
        examples = rng.sample(utterances, EXAMPLES_PER_ACTION)
        actions[intent] = make_action(
            intent, intent, scenario, examples,
            "Assistant action in the {domain} area handling {words} requests.")
    profiles = intent_token_profiles(
        {i: [u for u, _ in english["train"][i]] for i in intents})
    ranked = hard_distractors(profiles)

    for split in ("dev", "test"):
        episodes = []
        for locale, language in sorted(MASSIVE_LANGUAGES.items()):
            data = load_massive_locale(cache, locale)[split]
            pool = [(intent, utterance) for intent in intents
                    for utterance, _ in sorted(data.get(intent, []))]
            for intent, utterance in rng.sample(
                    pool, min(MASSIVE_PER_LANGUAGE[split], len(pool))):
                episodes.append({
                    "query": utterance,
                    "actions": pick_action_set(rng, intent, intents, ranked,
                                               MASSIVE_SET_SIZE),
                    "gold": intent, "language": language, "tags": ["multilingual"],
                })
        write_suite(output, split, "massive-multilingual", "MASSIVE 1.1",
                    "CC-BY-4.0", rng.seed_value, actions, episodes)


class SeededRandom(random.Random):
    def __init__(self, seed):
        super().__init__(seed)
        self.seed_value = seed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=pathlib.Path,
                        default=pathlib.Path(__file__).parent / "cache")
    parser.add_argument("--output", type=pathlib.Path,
                        default=pathlib.Path(__file__).parent.parent.parent
                        / "Benchmarks" / "episodes")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    rng = SeededRandom(args.seed)
    build_clinc(rng, args.cache, args.output)
    build_banking(rng, args.cache, args.output)
    build_massive(rng, args.cache, args.output)


if __name__ == "__main__":
    main()
