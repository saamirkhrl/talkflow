"use client";

import { useEffect, useState } from "react";

// idle: the field has focus and nothing is held. listening: fn is down and
// words are arriving. done: fn is up and the text is in place. sent: the app
// sent it (Return in a chat or a terminal), so the field is empty again.
export type Phase = "idle" | "listening" | "done" | "sent";
export type Dictation = { words: number; phase: Phase };

const EMPTY: Dictation = { words: 0, phase: "idle" };

// The part of `text` that has been typed so far.
export function typedText(text: string, d: Dictation): string {
  return d.phase === "sent" ? "" : text.split(" ").slice(0, d.words).join(" ");
}

// Plays `text` into a field word by word while `playing`, with human-ish
// pauses after commas and sentence ends, and loops for as long as it plays.
// When it stops playing it keeps its last frame while the scene fades out,
// then clears, so the next visit starts from an empty field.
export function useDictation(text: string, playing: boolean, reduced: boolean, sends: boolean): Dictation {
  const [dictation, setDictation] = useState(EMPTY);

  useEffect(() => {
    if (reduced) return;
    let timer: number;
    const later = (fn: () => void, ms: number) => {
      timer = window.setTimeout(fn, ms);
    };

    if (!playing) {
      later(() => setDictation(EMPTY), 700);
      return () => window.clearTimeout(timer);
    }

    const words = text.split(" ");

    const play = () => {
      setDictation(EMPTY);
      later(() => {
        setDictation({ words: 0, phase: "listening" });
        later(() => step(0), 450);
      }, 550);
    };

    const step = (i: number) => {
      if (i >= words.length) {
        later(() => {
          setDictation({ words: words.length, phase: "done" });
          later(() => {
            if (sends) setDictation({ words: words.length, phase: "sent" });
            later(play, sends ? 3600 : 3200);
          }, 900);
        }, 600);
        return;
      }
      const burst = Math.random() < 0.35 && i + 1 < words.length ? 2 : 1;
      const n = Math.min(words.length, i + burst);
      setDictation({ words: n, phase: "listening" });
      const word = words[n - 1];
      let delay = 110 + Math.random() * 150;
      if (/[,;]$/.test(word)) delay += 280 + Math.random() * 220;
      if (/[.?!]\s*$/.test(word)) delay += 620 + Math.random() * 420;
      if (Math.random() < 0.05) delay += 450;
      later(() => step(n), delay);
    };

    later(play, 0);
    return () => window.clearTimeout(timer);
  }, [text, playing, reduced, sends]);

  return reduced ? { words: text.split(" ").length, phase: "done" } : dictation;
}
