"use client";

import {
  ALargeSmall,
  AtSign,
  Bold,
  CheckCheck,
  ChevronDown,
  Clock,
  Code,
  Ellipsis,
  EllipsisVertical,
  File as FileIcon,
  Hash,
  Image as ImageIcon,
  Inbox,
  Info,
  Italic,
  Link,
  List,
  ListOrdered,
  Lock,
  Maximize2,
  Menu,
  Mic,
  Minus,
  Paperclip,
  Pencil,
  PenLine,
  Phone,
  Plus,
  Search,
  SendHorizontal,
  Smile,
  SquarePen,
  Star,
  Strikethrough,
  Trash2,
  Type,
  Video,
  X,
} from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";
import { typedText, type Dictation } from "./dictation";
import { Lights } from "./primitives";

export type MockProps = { text: string; d: Dictation };

function Caret({ className }: { className?: string }) {
  return (
    <span
      aria-hidden="true"
      className={cn("mx-px inline-block h-[1.2em] w-[1.5px] translate-y-[0.22em] animate-blink bg-current", className)}
    />
  );
}

// A text field's content: the dictated words so far with the caret after
// them, or the caret in front of the placeholder while it's still empty.
function FieldText({ typed, placeholder, caret }: { typed: string; placeholder: string; caret?: string }) {
  if (typed) {
    return (
      <>
        {typed}
        <Caret className={caret} />
      </>
    );
  }
  return (
    <>
      <Caret className={cn("ml-0", caret)} />
      <span className="opacity-45">{placeholder}</span>
    </>
  );
}

function Initials({ name, className }: { name: string; className?: string }) {
  const initials = name
    .split(" ")
    .map((w) => w[0])
    .join("")
    .slice(0, 2);
  return (
    <span aria-hidden="true" className={cn("grid shrink-0 place-items-center font-semibold text-white", className)}>
      {initials}
    </span>
  );
}

/* ------------------------------------------------------------------ Messages */

const MESSAGE_THREADS = [
  { name: "Maya Chen", preview: "we got a table outside at the noodle place on 5th 🍜", time: "6:14 PM" },
  { name: "Mom", preview: "Did you get home ok? Call me tomorrow", time: "Yesterday" },
  { name: "Jordan Lee", preview: "haha yes exactly, that's the one", time: "Yesterday" },
  { name: "Sam Rivera", preview: "Sent the photos from Saturday", time: "Tuesday" },
  { name: "Priya Shah", preview: "See you at 9!", time: "Monday" },
];

function Bubble({ me, children, className }: { me?: boolean; children: ReactNode; className?: string }) {
  return (
    <div
      className={cn(
        "max-w-[78%] rounded-[17px] px-3 py-[6px] leading-[1.35] break-words",
        me ? "self-end bg-[#0a84ff] text-white" : "self-start bg-[#e9e9eb] text-black",
        className,
      )}
    >
      {children}
    </div>
  );
}

export function MessagesMock({ text, d }: MockProps) {
  const sent = d.phase === "sent";
  return (
    <div className="flex h-full bg-white text-[13px] text-black">
      <aside className="hidden w-[188px] shrink-0 flex-col border-r border-black/10 bg-[#ececee] sm:flex">
        <div className="flex h-[46px] shrink-0 items-center justify-between pr-3 pl-3.5">
          <Lights />
          <SquarePen size={15} strokeWidth={1.75} className="text-black/50" />
        </div>
        <div className="mx-2.5 flex h-[26px] items-center gap-1.5 rounded-md bg-black/6 px-2 text-[12px] text-black/40">
          <Search size={12} strokeWidth={2} />
          Search
        </div>
        <ul className="mt-2.5 flex flex-col gap-0.5 px-2">
          {MESSAGE_THREADS.map((t, i) => (
            <li key={t.name} className={cn("flex gap-2 rounded-lg px-2 py-[7px]", i === 0 && "bg-[#0a84ff] text-white")}>
              <Initials name={t.name} className="size-8 rounded-full bg-linear-to-b from-[#a9aeb8] to-[#868b96] text-[12px]" />
              <div className="min-w-0 flex-1">
                <div className="flex items-baseline justify-between gap-1">
                  <span className="truncate text-[12.5px] font-semibold">{t.name}</span>
                  <span className={cn("shrink-0 text-[10.5px]", i === 0 ? "text-white/80" : "text-black/40")}>{t.time}</span>
                </div>
                <p className={cn("line-clamp-2 text-[11.5px] leading-[1.3]", i === 0 ? "text-white/85" : "text-black/45")}>
                  {t.preview}
                </p>
              </div>
            </li>
          ))}
        </ul>
      </aside>

      <section className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-[46px] shrink-0 items-center gap-1.5 border-b border-black/8 px-3.5">
          <Lights className="mr-3 sm:hidden" />
          <span className="text-black/45">To:</span>
          <span className="font-medium">Maya Chen</span>
          <span className="ml-auto flex items-center gap-4 text-black/45">
            <Video size={18} strokeWidth={1.6} />
            <Info size={16} strokeWidth={1.6} />
          </span>
        </header>

        <div className="flex min-h-0 flex-1 flex-col justify-end *:shrink-0 gap-1 overflow-hidden px-3.5 pb-3">
          <p className="mb-2 text-center text-[10.5px] leading-[1.4] text-black/40">
            <span className="font-medium">iMessage</span>
            <br />
            Today 6:12 PM
          </p>
          <Bubble>are you still coming tonight?</Bubble>
          <Bubble>we got a table outside at the noodle place on 5th 🍜</Bubble>
          {sent && (
            <>
              <Bubble me className="mt-2 animate-[pop-in_280ms_ease-out]">
                {text}
              </Bubble>
              <span className="pr-1 text-right text-[10.5px] text-black/40">Delivered</span>
            </>
          )}
        </div>

        <footer className="flex shrink-0 items-end gap-2 px-3 pb-3">
          <span className="grid size-[30px] shrink-0 place-items-center rounded-full bg-black/6 text-black/50">
            <Plus size={17} strokeWidth={2} />
          </span>
          <div className="flex min-h-[30px] flex-1 items-end gap-2 rounded-[16px] border border-black/15 py-[5px] pr-2.5 pl-3 leading-[1.35]">
            <div className="min-w-0 flex-1 break-words">
              <FieldText typed={typedText(text, d)} placeholder="iMessage" caret="bg-[#0a84ff]" />
            </div>
            <Smile size={16} strokeWidth={1.75} className="mb-px shrink-0 text-black/40" />
          </div>
        </footer>
      </section>
    </div>
  );
}

/* --------------------------------------------------------------------- Gmail */

const INBOX = [
  { from: "Daniel Okafor", subject: "Contract for the spring campaign", snippet: "Hi Alex, attached is the contract we talked about", time: "9:41 AM", unread: true },
  { from: "Figma", subject: "Maya commented on Checkout v3", snippet: "\"Can we try the button full width on mobile?\"", time: "8:15 AM", unread: true },
  { from: "Lena Fischer", subject: "Offsite dates", snippet: "Does the week of the 20th work for everyone?", time: "Oct 1", unread: false },
  { from: "Stripe", subject: "Your September payout", snippet: "Your payout of $4,812.20 is on its way", time: "Oct 1", unread: false },
  { from: "Tom Becker", subject: "Re: Q4 roadmap", snippet: "Agree on cutting the referral work for now", time: "Sep 30", unread: false },
  { from: "GitHub", subject: "[checkout-app] PR #214 merged", snippet: "Merged #214 into main", time: "Sep 30", unread: false },
];

const GMAIL_NAV: [ReactNode, string, string?][] = [
  [<Inbox key="i" size={16} strokeWidth={1.75} />, "Inbox", "2"],
  [<Star key="s" size={16} strokeWidth={1.75} />, "Starred"],
  [<Clock key="c" size={16} strokeWidth={1.75} />, "Snoozed"],
  [<SendHorizontal key="t" size={16} strokeWidth={1.75} />, "Sent"],
  [<FileIcon key="d" size={16} strokeWidth={1.75} />, "Drafts", "1"],
];

export function GmailMock({ text, d }: MockProps) {
  const typed = typedText(text, d);
  // The blank lines around the greeting and sign-off arrive on release.
  const body = d.phase === "done" ? typed : typed.replace(/\n+/g, " ");

  return (
    <div className="flex h-full flex-col bg-[#f8fafd] text-[13px] text-[#1f1f1f]">
      <div className="flex h-[38px] shrink-0 items-center gap-3 border-b border-black/8 bg-[#e9edf3] px-3.5">
        <Lights />
        <div className="mx-auto flex h-[24px] w-full max-w-[260px] items-center justify-center gap-1.5 rounded-md bg-white/80 text-[12px] text-black/55">
          <Lock size={11} strokeWidth={2} />
          mail.google.com
        </div>
        <span className="w-[52px] shrink-0" />
      </div>

      <div className="flex h-[52px] shrink-0 items-center gap-3 px-4">
        <Menu size={18} strokeWidth={1.75} className="text-black/60" />
        <span className="text-[19px] tracking-[-0.01em] text-black/65">Gmail</span>
        <div className="ml-4 hidden h-9 flex-1 items-center gap-2.5 rounded-full bg-[#e9eef6] px-4 text-black/50 sm:flex">
          <Search size={16} strokeWidth={1.75} />
          Search mail
        </div>
        <Initials name="Alex Kim" className="ml-auto size-7 rounded-full bg-[#5b8def] text-[11px] sm:ml-0" />
      </div>

      <div className="relative flex min-h-0 flex-1">
        <nav className="hidden w-[150px] shrink-0 flex-col gap-0.5 pr-2 sm:flex">
          <span className="mb-3 ml-2 flex h-11 w-fit items-center gap-2.5 rounded-2xl bg-[#c2e7ff] pr-5 pl-4 font-medium">
            <Pencil size={16} strokeWidth={1.75} />
            Compose
          </span>
          {GMAIL_NAV.map(([icon, label, count], i) => (
            <span
              key={label}
              className={cn(
                "flex h-8 items-center gap-3.5 rounded-r-full pr-3 pl-5",
                i === 0 && "bg-[#d3e3fd] font-semibold",
              )}
            >
              {icon}
              <span className="flex-1">{label}</span>
              {count && <span className="text-[11.5px]">{count}</span>}
            </span>
          ))}
        </nav>

        <ul className="min-w-0 flex-1 overflow-hidden rounded-tl-2xl bg-white">
          {INBOX.map((m) => (
            <li key={m.subject} className="flex h-10 items-center gap-3 border-b border-black/6 px-4 text-[12.5px]">
              <span className={cn("w-[96px] shrink-0 truncate", m.unread && "font-bold")}>{m.from}</span>
              <span className="min-w-0 flex-1 truncate">
                <span className={cn(m.unread && "font-bold")}>{m.subject}</span>
                <span className="text-black/50"> - {m.snippet}</span>
              </span>
              <span className={cn("shrink-0 text-[11.5px]", m.unread ? "font-bold" : "text-black/55")}>{m.time}</span>
            </li>
          ))}
        </ul>

        <div className="absolute inset-x-2 top-2 bottom-0 flex flex-col overflow-hidden rounded-t-xl bg-white shadow-[0_8px_30px_rgba(0,0,0,0.22)] sm:inset-x-auto sm:right-4 sm:left-auto sm:w-[min(360px,70%)]">
          <div className="flex h-10 shrink-0 items-center gap-3 bg-[#f2f6fc] px-4 font-medium">
            <span className="flex-1">New Message</span>
            <Minus size={15} strokeWidth={2} className="text-black/60" />
            <Maximize2 size={13} strokeWidth={2} className="text-black/60" />
            <X size={15} strokeWidth={2} className="text-black/60" />
          </div>
          <div className="mx-4 flex h-9 shrink-0 items-center gap-2 border-b border-black/10">
            <span className="text-black/55">To</span>
            <span className="flex h-6 items-center gap-1.5 rounded-full border border-black/15 pr-2.5 pl-0.5 text-[12.5px]">
              <Initials name="Daniel Okafor" className="size-5 rounded-full bg-[#e8710a] text-[9px]" />
              Daniel Okafor
            </span>
          </div>
          <div className="mx-4 flex h-9 shrink-0 items-center border-b border-black/10">
            Re: Contract for the spring campaign
          </div>
          <div className="min-h-0 flex-1 overflow-hidden px-4 pt-3 leading-[1.5] whitespace-pre-wrap">
            <FieldText typed={body} placeholder="" caret="bg-black" />
          </div>
          <div className="flex h-14 shrink-0 items-center gap-3.5 px-4 text-black/60">
            <span className="flex h-9 items-center rounded-full bg-[#0b57d0] font-medium text-white">
              <span className="pr-3 pl-5">Send</span>
              <span className="flex h-full items-center border-l border-white/30 pr-2.5 pl-2">
                <ChevronDown size={15} strokeWidth={2} />
              </span>
            </span>
            <Type size={16} strokeWidth={1.75} />
            <Paperclip size={16} strokeWidth={1.75} />
            <Link size={16} strokeWidth={1.75} className="hidden sm:block" />
            <Smile size={16} strokeWidth={1.75} className="hidden sm:block" />
            <ImageIcon size={16} strokeWidth={1.75} className="hidden sm:block" />
            <PenLine size={16} strokeWidth={1.75} className="hidden md:block" />
            <EllipsisVertical size={16} strokeWidth={1.75} />
            <Trash2 size={16} strokeWidth={1.75} className="ml-auto" />
          </div>
        </div>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ WhatsApp */

const WA_CHATS = [
  { name: "Family", preview: "Mum: I'm doing the roast, someone bring dessert", time: "12:41", unread: 2 },
  { name: "Lily", preview: "lol same", time: "11:02", unread: 0 },
  { name: "Five-a-side", preview: "Ben: who's in for Thursday?", time: "Yesterday", unread: 0 },
  { name: "Ben Carter", preview: "Voice message (0:42)", time: "Yesterday", unread: 0 },
  { name: "Aisha", preview: "Thank you!! See you then", time: "Monday", unread: 0 },
];

function WaBubble({ me, author, color, time, children, className }: {
  me?: boolean;
  author?: string;
  color?: string;
  time: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "max-w-[80%] rounded-lg px-2.5 pt-1.5 pb-1 leading-[1.4] break-words shadow-[0_1px_0.5px_rgba(11,20,26,0.13)]",
        me ? "self-end rounded-tr-none bg-[#d9fdd3]" : "self-start rounded-tl-none bg-white",
        className,
      )}
    >
      {author && <div className={cn("text-[12px] font-medium", color)}>{author}</div>}
      {children}
      <span className="float-right mt-1.5 ml-2.5 flex items-center gap-1 text-[10.5px] leading-none text-black/45">
        {time}
        {me && <CheckCheck size={14} strokeWidth={2} className="text-[#53bdeb]" />}
      </span>
    </div>
  );
}

export function WhatsAppMock({ text, d }: MockProps) {
  const typed = typedText(text, d);
  const sent = d.phase === "sent";

  return (
    <div className="flex h-full bg-white text-[13px] text-[#111b21]">
      <aside className="hidden w-[210px] shrink-0 flex-col border-r border-black/10 sm:flex">
        <div className="flex h-[46px] shrink-0 items-center px-3.5">
          <Lights />
        </div>
        <div className="flex items-center justify-between px-3.5 pb-2">
          <span className="text-[19px] font-bold">Chats</span>
          <SquarePen size={16} strokeWidth={1.75} className="text-black/55" />
        </div>
        <div className="mx-3 flex h-8 items-center gap-2 rounded-full bg-[#f0f2f5] px-3 text-[12px] text-black/45">
          <Search size={13} strokeWidth={2} className="shrink-0" />
          <span className="truncate">Search or start a new chat</span>
        </div>
        <ul className="mt-2 flex flex-col px-1.5">
          {WA_CHATS.map((c, i) => (
            <li key={c.name} className={cn("flex gap-2.5 rounded-lg px-2 py-2", i === 0 && "bg-[#f0f2f5]")}>
              <Initials
                name={c.name}
                className={cn("size-9 rounded-full text-[12px]", ["bg-[#25d366]", "bg-[#a389f4]", "bg-[#f7a33b]", "bg-[#53bdeb]", "bg-[#ff7a8a]"][i])}
              />
              <div className="min-w-0 flex-1">
                <div className="flex items-baseline justify-between gap-1">
                  <span className="truncate text-[13px]">{c.name}</span>
                  <span className={cn("shrink-0 text-[10.5px]", c.unread ? "text-[#1fa855]" : "text-black/45")}>{c.time}</span>
                </div>
                <div className="flex items-center gap-1">
                  <p className="min-w-0 flex-1 truncate text-[12px] text-black/50">{c.preview}</p>
                  {c.unread > 0 && (
                    <span className="grid size-[17px] shrink-0 place-items-center rounded-full bg-[#25d366] text-[10px] font-semibold text-white">
                      {c.unread}
                    </span>
                  )}
                </div>
              </div>
            </li>
          ))}
        </ul>
      </aside>

      <section className="flex min-w-0 flex-1 flex-col bg-[#efeae2]">
        <header className="flex h-[52px] shrink-0 items-center gap-2.5 border-b border-black/8 bg-white px-3.5">
          <Lights className="mr-1 sm:hidden" />
          <Initials name="Family" className="size-8 rounded-full bg-[#25d366] text-[12px]" />
          <div className="min-w-0 flex-1 leading-[1.25]">
            <div className="font-medium">Family</div>
            <div className="truncate text-[11.5px] text-black/50">Dad, Mum, Lily, You</div>
          </div>
          <span className="flex items-center gap-4 text-black/55">
            <Video size={18} strokeWidth={1.6} />
            <Phone size={16} strokeWidth={1.6} className="hidden sm:block" />
            <Search size={16} strokeWidth={1.6} />
          </span>
        </header>

        <div className="flex min-h-0 flex-1 flex-col justify-end *:shrink-0 gap-1.5 overflow-hidden px-4 pb-3">
          <span className="mb-1 self-center rounded-md bg-white px-2.5 py-1 text-[11px] text-black/55 shadow-[0_1px_0.5px_rgba(11,20,26,0.13)]">
            Today
          </span>
          <WaBubble author="Dad" color="text-[#c4532d]" time="12:40">
            Is everyone still good for Sunday lunch?
          </WaBubble>
          <WaBubble author="Mum" color="text-[#7f66ff]" time="12:41">
            I&apos;m doing the roast, someone bring dessert 🍰
          </WaBubble>
          {sent && (
            <WaBubble me time="12:43" className="mt-1 animate-[pop-in_280ms_ease-out]">
              {text}
            </WaBubble>
          )}
        </div>

        <footer className="flex shrink-0 items-end gap-3 bg-[#f0f2f5] px-3 py-2 text-black/55">
          <Plus size={21} strokeWidth={1.75} className="mb-[7px] shrink-0" />
          <div className="flex min-h-9 flex-1 items-end gap-2 rounded-lg bg-white py-2 pr-2.5 pl-3 leading-[1.4] text-[#111b21]">
            <Smile size={18} strokeWidth={1.6} className="shrink-0 text-black/50" />
            <div className="min-w-0 flex-1 break-words">
              <FieldText typed={typed} placeholder="Type a message" caret="bg-[#00a884]" />
            </div>
          </div>
          {typed ? (
            <SendHorizontal size={20} strokeWidth={1.75} className="mb-2 shrink-0" />
          ) : (
            <Mic size={20} strokeWidth={1.75} className="mb-2 shrink-0" />
          )}
        </footer>
      </section>
    </div>
  );
}

/* --------------------------------------------------------------------- Slack */

const SLACK_CHANNELS = ["general", "checkout-launch", "design", "random"];

function SlackMessage({ name, color, time, children, className }: {
  name: string;
  color: string;
  time: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("flex gap-2.5", className)}>
      <Initials name={name} className={cn("size-9 rounded-lg text-[12px]", color)} />
      <div className="min-w-0 flex-1 leading-[1.45]">
        <div className="flex items-baseline gap-2">
          <span className="font-bold">{name}</span>
          <span className="text-[11.5px] text-black/50">{time}</span>
        </div>
        <p className="break-words">{children}</p>
      </div>
    </div>
  );
}

export function SlackMock({ text, d }: MockProps) {
  const typed = typedText(text, d);
  const sent = d.phase === "sent";

  return (
    <div className="flex h-full flex-col bg-[#3f0e40] text-[13.5px] text-[#1d1c1d]">
      <div className="flex h-[38px] shrink-0 items-center gap-3 px-3.5">
        <Lights />
        <div className="mx-auto flex h-[24px] w-full max-w-[300px] items-center justify-center gap-1.5 rounded-md bg-white/15 text-[12px] text-white/75">
          <Search size={12} strokeWidth={2} />
          Search Acme
        </div>
        <span className="w-[52px] shrink-0" />
      </div>

      <div className="flex min-h-0 flex-1">
        <aside className="hidden w-[180px] shrink-0 flex-col text-white/70 sm:flex">
          <div className="flex h-11 items-center gap-1 border-b border-white/10 px-4 text-[15px] font-bold text-white">
            Acme <ChevronDown size={14} strokeWidth={2.5} />
          </div>
          <div className="mt-3 px-4 pb-1 text-[12.5px]">Channels</div>
          {SLACK_CHANNELS.map((c) => (
            <span
              key={c}
              className={cn(
                "mx-2 flex h-7 items-center gap-1.5 rounded-md px-2",
                c === "checkout-launch" && "bg-[#1164a3] font-semibold text-white",
              )}
            >
              <Hash size={13} strokeWidth={2} />
              {c}
            </span>
          ))}
          <div className="mt-3 px-4 pb-1 text-[12.5px]">Direct messages</div>
          {["Priya Shah", "Tom Becker"].map((n, i) => (
            <span key={n} className="mx-2 flex h-7 items-center gap-2 px-2">
              <Initials name={n} className={cn("size-[18px] rounded text-[8px]", i === 0 ? "bg-[#e8912d]" : "bg-[#2bac76]")} />
              {n}
            </span>
          ))}
        </aside>

        <section className="flex min-w-0 flex-1 flex-col overflow-hidden bg-white sm:rounded-tl-lg">
          <header className="flex h-11 shrink-0 items-center gap-1 border-b border-black/10 px-4 text-[15px] font-bold">
            <Hash size={15} strokeWidth={2.25} />
            checkout-launch
            <ChevronDown size={14} strokeWidth={2.5} className="text-black/50" />
          </header>

          <div className="flex min-h-0 flex-1 flex-col justify-end *:shrink-0 gap-3.5 overflow-hidden px-4 pb-3">
            <SlackMessage name="Tom Becker" color="bg-[#2bac76]" time="9:48 AM">
              Copy for the new pay button is in Figma, shout if anything reads weird 🙏
            </SlackMessage>
            <SlackMessage name="Priya Shah" color="bg-[#e8912d]" time="10:02 AM">
              Morning! Where are we on the payment fix? Would love to get it in front of QA today.
            </SlackMessage>
            {sent && (
              <SlackMessage name="Alex Kim" color="bg-[#5b8def]" time="10:06 AM" className="animate-[pop-in_280ms_ease-out]">
                {text}
              </SlackMessage>
            )}
          </div>

          <div className="mx-4 mb-3 shrink-0 rounded-lg border border-black/30">
            <div className="flex h-8 items-center gap-3.5 rounded-t-lg bg-black/3 px-2.5 text-black/40">
              <Bold size={14} strokeWidth={2} />
              <Italic size={14} strokeWidth={2} />
              <Strikethrough size={14} strokeWidth={2} />
              <Link size={14} strokeWidth={2} />
              <ListOrdered size={14} strokeWidth={2} className="hidden sm:block" />
              <List size={14} strokeWidth={2} className="hidden sm:block" />
              <Code size={14} strokeWidth={2} className="hidden sm:block" />
            </div>
            <div className="min-h-9 px-3 py-2 leading-[1.45] break-words">
              <FieldText typed={typed} placeholder="Message #checkout-launch" caret="bg-black" />
            </div>
            <div className="flex h-9 items-center gap-3.5 px-2.5 text-black/55">
              <span className="grid size-6 place-items-center rounded-full bg-black/6">
                <Plus size={15} strokeWidth={2} />
              </span>
              <ALargeSmall size={16} strokeWidth={1.75} />
              <Smile size={16} strokeWidth={1.75} />
              <AtSign size={16} strokeWidth={1.75} />
              <Video size={16} strokeWidth={1.75} className="hidden sm:block" />
              <Mic size={16} strokeWidth={1.75} className="hidden sm:block" />
              <span
                className={cn(
                  "ml-auto flex h-7 items-center rounded-md px-2 transition-colors",
                  typed ? "bg-[#007a5a] text-white" : "text-black/30",
                )}
              >
                <SendHorizontal size={15} strokeWidth={2} />
              </span>
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------- Notion */

const NOTION_PAGES = [
  ["📝", "Meeting notes"],
  ["🗺️", "Roadmap"],
  ["🚀", "Launch plan"],
  ["🧾", "Checkout retro"],
  ["📚", "Team wiki"],
];

export function NotionMock({ text, d }: MockProps) {
  const typed = typedText(text, d);

  return (
    <div className="flex h-full bg-white text-[13.5px] text-[#37352f]">
      <aside className="hidden w-[172px] shrink-0 flex-col bg-[#f7f7f5] text-[12.5px] text-[#5f5e5b] sm:flex">
        <div className="flex h-[42px] shrink-0 items-center px-3.5">
          <Lights />
        </div>
        <div className="flex items-center gap-2 px-3 pb-2 font-medium text-[#37352f]">
          <span className="grid size-5 place-items-center rounded bg-[#37352f] text-[10px] font-semibold text-white">A</span>
          Acme
          <ChevronDown size={12} strokeWidth={2} className="text-black/40" />
        </div>
        <span className="flex h-7 items-center gap-2 px-3">
          <Search size={14} strokeWidth={1.75} />
          Search
        </span>
        <span className="flex h-7 items-center gap-2 px-3">
          <Inbox size={14} strokeWidth={1.75} />
          Inbox
        </span>
        <div className="mt-3 px-3 pb-1 text-[11.5px] font-medium text-black/40">Teamspace</div>
        {NOTION_PAGES.map(([icon, name]) => (
          <span
            key={name}
            className={cn(
              "mx-1.5 flex h-7 items-center gap-2 rounded-md px-1.5",
              name === "Checkout retro" && "bg-black/5 font-medium text-[#37352f]",
            )}
          >
            <span className="w-4 text-center text-[13px]">{icon}</span>
            {name}
          </span>
        ))}
      </aside>

      <section className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-[42px] shrink-0 items-center gap-2 px-3.5 text-[12.5px]">
          <Lights className="mr-2 sm:hidden" />
          <span className="truncate text-black/50">🚀 Launch plan</span>
          <span className="text-black/30">/</span>
          <span className="truncate">🧾 Checkout retro</span>
          <span className="ml-auto flex items-center gap-3.5 text-black/50">
            <span className="hidden sm:inline">Share</span>
            <Star size={15} strokeWidth={1.75} />
            <Ellipsis size={16} strokeWidth={1.75} />
          </span>
        </header>

        <div className="min-h-0 flex-1 overflow-hidden px-[clamp(20px,7%,52px)] pt-5 leading-[1.55]">
          <div className="text-[34px] leading-none">🧾</div>
          <h3 className="mt-3 text-[26px] leading-[1.2] font-bold tracking-[-0.01em]">Checkout retro</h3>
          <div className="mt-2.5 flex gap-6 text-[12.5px]">
            <span className="w-16 text-black/45">Date</span>
            <span>October 2, 2026</span>
          </div>
          <div className="mt-1 flex gap-6 text-[12.5px]">
            <span className="w-16 text-black/45">Team</span>
            <span className="rounded bg-[#e3e2e0] px-1.5">Payments</span>
          </div>

          <h4 className="mt-5 text-[17px] font-semibold">What went well</h4>
          <ul className="mt-1 list-disc pl-5 marker:text-[#37352f]">
            <li>No double charges since the pay button fix shipped.</li>
            <li>Support tickets about checkout are down by half.</li>
          </ul>

          <h4 className="mt-4 text-[17px] font-semibold">Next sprint</h4>
          <p className="mt-1 break-words">
            <FieldText typed={typed} placeholder="Write, press 'space' for AI, '/' for commands…" caret="bg-[#37352f]" />
          </p>
        </div>
      </section>
    </div>
  );
}
