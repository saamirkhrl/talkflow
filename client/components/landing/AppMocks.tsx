"use client";

import {
  ALargeSmall,
  Archive,
  ArrowLeft,
  ArrowRight,
  AtSign,
  AudioLines,
  Bell,
  Bold,
  Bookmark,
  Calendar,
  CheckCheck,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronsUpDown,
  CircleDashed,
  CircleHelp,
  Clock,
  Code,
  Ellipsis,
  EllipsisVertical,
  File as FileIcon,
  Folder,
  Hash,
  Headphones,
  House,
  Image as ImageIcon,
  Inbox,
  Italic,
  LayoutGrid,
  Link,
  List,
  ListFilter,
  ListOrdered,
  Maximize2,
  Menu,
  MessageCircle,
  MessageSquare,
  MessagesSquare,
  Mic,
  Minus,
  Paperclip,
  Pencil,
  PenLine,
  Phone,
  Plus,
  RotateCw,
  Search,
  SendHorizontal,
  Settings,
  SlidersHorizontal,
  Smile,
  Sparkles,
  Square,
  SquarePen,
  Star,
  Strikethrough,
  Tag,
  Trash2,
  Type,
  User,
  Users,
  Video,
  X,
} from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";
import { APP_LOGOS } from "./brand-logos.generated";
import { BrandLogo } from "./BrandLogo";
import { typedText, type Dictation } from "./dictation";
import { Lights } from "./primitives";

export type MockProps = { text: string; d: Dictation };

const GMAIL_LOGO = APP_LOGOS.find((logo) => logo.name === "Gmail")!;

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
    .slice(0, 2)
    .toUpperCase();
  return (
    <span aria-hidden="true" className={cn("grid shrink-0 place-items-center font-semibold text-white", className)}>
      {initials}
    </span>
  );
}

// macOS contact monogram: white initials on the grey gradient Contacts uses.
const MONOGRAM = "rounded-full bg-linear-to-b from-[#a9aeb8] to-[#858a95]";

/* ------------------------------------------------------------------ Messages */
// macOS Tahoe: a floating sidebar with pinned contacts, a centered contact
// header, glass buttons, and bubbles with tails.

const PINNED = ["Mom", "Jordan Lee", "Sam Rivera"];

const MESSAGE_THREADS = [
  { name: "Maya Chen", preview: "we grabbed a table outside, the whole YC batch is here lol", time: "6:14 PM", unread: false },
  { name: "Launch crew", preview: "Priya: posting at 8 sharp 🚀", time: "5:52 PM", unread: true },
  { name: "Daniel Okafor", preview: "Great meeting you Tuesday!", time: "Yesterday", unread: false },
  { name: "Priya Shah", preview: "See you at 9!", time: "Monday", unread: false },
];

function BubbleTail({ me }: { me?: boolean }) {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 11 17"
      className={cn("absolute bottom-0 h-[17px] w-[11px]", me ? "-right-[5px] -scale-x-100" : "-left-[5px]")}
    >
      <path d="M11 0v17H0c4.5-1 8-4.5 8-10V0z" fill="currentColor" />
    </svg>
  );
}

function Bubble({ me, tail, children, className }: { me?: boolean; tail?: boolean; children: ReactNode; className?: string }) {
  return (
    <div
      className={cn(
        "relative max-w-[76%] rounded-[18px] px-3 py-[6px] leading-[1.35] break-words",
        me ? "self-end bg-[#0a7cff] text-white" : "self-start bg-[#e9e9eb] text-black",
        className,
      )}
    >
      {tail && (
        <span className={me ? "text-[#0a7cff]" : "text-[#e9e9eb]"}>
          <BubbleTail me={me} />
        </span>
      )}
      <span className="relative">{children}</span>
    </div>
  );
}

function Glass({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <span
      className={cn(
        "grid shrink-0 place-items-center rounded-full border border-black/6 bg-white/80 text-black/60 shadow-[0_1px_4px_rgba(0,0,0,0.08)] backdrop-blur",
        className,
      )}
    >
      {children}
    </span>
  );
}

export function MessagesMock({ text, d }: MockProps) {
  const sent = d.phase === "sent";
  return (
    <div className="relative flex h-full bg-white text-[13px] text-black">
      <aside className="m-2 mr-0 hidden w-[196px] shrink-0 flex-col overflow-hidden rounded-[18px] border border-black/6 bg-[#f1f1f3] shadow-[0_2px_10px_rgba(0,0,0,0.06)] @min-[520px]:flex">
        <div className="flex h-10 shrink-0 items-center justify-between pr-3 pl-3.5">
          <Lights />
          <ListFilter size={15} strokeWidth={1.75} className="text-black/50" />
        </div>
        <div className="mx-2.5 flex h-[27px] items-center gap-1.5 rounded-full bg-black/6 px-2.5 text-[12px] text-black/40">
          <Search size={12} strokeWidth={2} />
          Search
        </div>
        <div className="mt-3 grid grid-cols-3 px-2">
          {PINNED.map((name) => (
            <div key={name} className="flex flex-col items-center gap-1">
              <Initials name={name} className={cn(MONOGRAM, "size-[42px] text-[15px]")} />
              <span className="max-w-full truncate text-[10.5px] text-black/70">{name.split(" ")[0]}</span>
            </div>
          ))}
        </div>
        <ul className="mt-2.5 flex flex-col gap-0.5 px-1.5">
          {MESSAGE_THREADS.map((t, i) => (
            <li
              key={t.name}
              className={cn("relative flex gap-2 rounded-[10px] py-[7px] pr-2 pl-3", i === 0 && "bg-[#0a7cff] text-white")}
            >
              {t.unread && <span className="absolute top-1/2 left-[3px] size-[7px] -translate-y-1/2 rounded-full bg-[#0a7cff]" />}
              <Initials name={t.name} className={cn(MONOGRAM, "size-8 text-[11.5px]")} />
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

      <section className="relative flex min-w-0 flex-1 flex-col">
        <header className="flex shrink-0 items-start justify-between px-3 pt-2.5">
          <span className="flex items-center gap-3">
            <Lights className="@min-[520px]:hidden" />
            <Glass className="size-[30px]">
              <SquarePen size={14} strokeWidth={1.75} />
            </Glass>
          </span>
          <div className="flex flex-col items-center gap-1">
            <Initials name="Maya Chen" className={cn(MONOGRAM, "size-[34px] text-[12.5px]")} />
            <span className="flex items-center gap-0.5 rounded-full border border-black/6 bg-white/85 px-2.5 py-0.5 text-[11.5px] font-medium shadow-[0_1px_4px_rgba(0,0,0,0.08)]">
              Maya Chen
              <ChevronRight size={11} strokeWidth={2.25} className="text-black/40" />
            </span>
          </div>
          <Glass className="size-[30px]">
            <Video size={15} strokeWidth={1.75} />
          </Glass>
        </header>

        <div className="flex min-h-0 flex-1 flex-col justify-end gap-[3px] overflow-hidden px-4 pb-2.5 *:shrink-0">
          <p className="mb-2 text-center text-[10.5px] text-black/40">
            <span className="font-medium">iMessage</span> · Today 6:12 PM
          </p>
          <Bubble>are you still coming tonight?</Bubble>
          <Bubble tail>we grabbed a table outside, the whole YC batch is here lol</Bubble>
          {sent && (
            <>
              <Bubble me tail className="mt-2 animate-[pop-in_280ms_ease-out]">
                {text}
              </Bubble>
              <span className="pr-1 text-right text-[10.5px] text-black/40">Delivered</span>
            </>
          )}
        </div>

        <footer className="flex shrink-0 items-end gap-2 px-3 pb-3">
          <Glass className="size-[30px]">
            <Plus size={16} strokeWidth={2} />
          </Glass>
          <div className="min-h-[30px] flex-1 rounded-[16px] border border-black/12 bg-white/85 px-3 py-[5px] leading-[1.35] break-words shadow-[0_1px_4px_rgba(0,0,0,0.05)]">
            <FieldText typed={typedText(text, d)} placeholder="iMessage" caret="bg-[#0a7cff]" />
          </div>
          <Glass className="size-[30px]">
            <Smile size={16} strokeWidth={1.75} />
          </Glass>
        </footer>
      </section>
    </div>
  );
}

/* --------------------------------------------------------------------- Gmail */
// Gmail on the web, in Chrome, with a reply being dictated into Compose.

const INBOX = [
  { from: "Daniel Okafor", subject: "Following up from Tuesday", snippet: "Great meeting you. Could you send over the deck?", time: "9:41 AM", unread: true },
  { from: "Hacker News", subject: "Your post is on the front page", snippet: "Show HN: We built the waitlist we wished existed", time: "8:15 AM", unread: true },
  { from: "Lena Fischer", subject: "Offsite dates", snippet: "Does the week of the 20th work for everyone?", time: "Oct 1", unread: false },
  { from: "Stripe", subject: "Your September payout", snippet: "Your payout of $4,812.20 is on its way", time: "Oct 1", unread: false },
  { from: "Tom Becker", subject: "Re: Q4 roadmap", snippet: "Agree on cutting the referral work for now", time: "Sep 30", unread: false },
  { from: "GitHub", subject: "[waitlist] PR #214 merged", snippet: "Merged #214 into main", time: "Sep 30", unread: false },
  { from: "Vercel", subject: "Deployment ready", snippet: "waitlist-web is live on production", time: "Sep 29", unread: false },
];

const GMAIL_NAV: [ReactNode, string, string?][] = [
  [<Inbox key="i" size={17} strokeWidth={1.75} />, "Inbox", "2"],
  [<Star key="s" size={17} strokeWidth={1.75} />, "Starred"],
  [<Clock key="c" size={17} strokeWidth={1.75} />, "Snoozed"],
  [<SendHorizontal key="t" size={17} strokeWidth={1.75} />, "Sent"],
  [<FileIcon key="d" size={17} strokeWidth={1.75} />, "Drafts", "1"],
  [<ChevronDown key="m" size={17} strokeWidth={1.75} />, "More"],
];

export function GmailMock({ text, d }: MockProps) {
  const typed = typedText(text, d);
  // The blank lines around the greeting and sign-off arrive on release.
  const body = d.phase === "done" ? typed : typed.replace(/\n+/g, " ");

  return (
    <div className="flex h-full flex-col bg-[#f8fafd] text-[13px] text-[#1f1f1f]">
      {/* Chrome: tab strip, then the toolbar with the address bar. */}
      <div className="flex h-[36px] shrink-0 items-end gap-2 bg-[#dfe3e7] px-3">
        <Lights className="mb-[11px] mr-2" />
        <div className="relative flex h-[30px] w-[min(230px,60%)] items-center gap-2 rounded-t-[10px] bg-white px-3 text-[12px]">
          <BrandLogo logo={GMAIL_LOGO} className="h-[11px] w-[14px] shrink-0" />
          <span className="min-w-0 flex-1 truncate">Inbox (2) - alex@acme.co - Gmail</span>
          <X size={12} strokeWidth={2} className="shrink-0 text-black/50" />
        </div>
        <Plus size={15} strokeWidth={2} className="mb-[8px] text-black/50" />
      </div>
      <div className="flex h-[38px] shrink-0 items-center gap-3 border-b border-black/8 bg-white px-3 text-black/55">
        <ArrowLeft size={15} strokeWidth={2} />
        <ArrowRight size={15} strokeWidth={2} className="text-black/25" />
        <RotateCw size={14} strokeWidth={2} />
        <div className="flex h-[26px] min-w-0 flex-1 items-center gap-2 rounded-full bg-[#eef1f4] px-3 text-[12px] text-black/70">
          <SlidersHorizontal size={12} strokeWidth={2} className="shrink-0 text-black/50" />
          <span className="truncate">mail.google.com/mail/u/0/#inbox</span>
        </div>
        <Initials name="Alex Kim" className="size-[22px] rounded-full bg-[#5b8def] text-[9px]" />
      </div>

      <div className="relative flex min-h-0 flex-1 flex-col">
        {/* Gmail */}
        <div className="flex h-[54px] shrink-0 items-center gap-2 pr-3 pl-4">
          <Menu size={18} strokeWidth={1.75} className="mr-2 shrink-0 text-black/60" />
          <BrandLogo logo={GMAIL_LOGO} className="h-[20px] w-[26px] shrink-0" />
          <span className="mr-5 text-[19px] tracking-[-0.01em] text-[#444746]">Gmail</span>
          <div className="hidden h-10 min-w-0 flex-1 items-center gap-3 rounded-full bg-[#e9eef6] px-4 text-[#444746] @min-[520px]:flex">
            <Search size={17} strokeWidth={1.75} className="shrink-0" />
            <span className="flex-1 truncate">Search mail</span>
            <SlidersHorizontal size={16} strokeWidth={1.75} className="shrink-0" />
          </div>
          <span className="ml-auto flex items-center gap-3.5 pl-3 text-[#444746]">
            <CircleHelp size={17} strokeWidth={1.75} className="hidden @min-[640px]:block" />
            <Settings size={17} strokeWidth={1.75} className="hidden @min-[640px]:block" />
            <Sparkles size={17} strokeWidth={1.75} className="text-[#0b57d0]" />
            <LayoutGrid size={16} strokeWidth={1.75} />
            <Initials name="Alex Kim" className="size-[28px] rounded-full bg-[#5b8def] text-[11px]" />
          </span>
        </div>

        <div className="relative flex min-h-0 flex-1">
          <nav className="hidden w-[148px] shrink-0 flex-col pr-2 @min-[520px]:flex">
            <span className="mb-3 ml-2 flex h-12 w-fit items-center gap-3 rounded-2xl bg-[#c2e7ff] pr-5 pl-4 font-medium text-[#001d35]">
              <Pencil size={17} strokeWidth={1.75} />
              Compose
            </span>
            {GMAIL_NAV.map(([icon, label, count], i) => (
              <span
                key={label}
                className={cn(
                  "flex h-8 items-center gap-3.5 rounded-r-full pr-3 pl-5 text-[#202124]",
                  i === 0 && "bg-[#d3e3fd] font-bold text-[#001d35]",
                )}
              >
                {icon}
                <span className="flex-1">{label}</span>
                {count && <span className="text-[11.5px]">{count}</span>}
              </span>
            ))}
          </nav>

          <div className="mr-0 min-w-0 flex-1 overflow-hidden rounded-t-2xl bg-white @min-[520px]:mr-3">
            <div className="flex h-10 items-center gap-4 px-4 text-[#444746]">
              <span className="flex items-center gap-0.5">
                <Square size={15} strokeWidth={1.75} />
                <ChevronDown size={11} strokeWidth={2} />
              </span>
              <RotateCw size={14} strokeWidth={1.75} />
              <EllipsisVertical size={15} strokeWidth={1.75} />
              <span className="ml-auto hidden items-center gap-3 text-[11.5px] @min-[640px]:flex">
                1-50 of 2,316
                <ChevronLeft size={15} strokeWidth={1.75} className="text-black/30" />
                <ChevronRight size={15} strokeWidth={1.75} />
              </span>
            </div>
            <div className="flex h-11 border-b border-black/8 text-[13px] text-[#444746]">
              <span className="relative flex flex-1 items-center gap-3 px-4 font-medium text-[#0b57d0]">
                <Inbox size={17} strokeWidth={1.75} />
                Primary
                <span className="absolute inset-x-3 bottom-0 h-[3px] rounded-t-full bg-[#0b57d0]" />
              </span>
              <span className="flex flex-1 items-center gap-3 px-4">
                <Tag size={16} strokeWidth={1.75} />
                Promotions
              </span>
              <span className="hidden flex-1 items-center gap-3 px-4 @min-[640px]:flex">
                <Users size={16} strokeWidth={1.75} />
                Social
              </span>
            </div>
            <ul>
              {INBOX.map((m) => (
                <li
                  key={m.subject}
                  className={cn(
                    "flex h-10 items-center gap-3 border-b border-black/6 px-4 text-[12.5px]",
                    m.unread ? "bg-white" : "bg-[#f2f6fc]",
                  )}
                >
                  <Square size={14} strokeWidth={1.75} className="shrink-0 text-black/35" />
                  <Star size={14} strokeWidth={1.75} className="shrink-0 text-black/35" />
                  <span className={cn("w-[92px] shrink-0 truncate", m.unread && "font-bold")}>{m.from}</span>
                  <span className="min-w-0 flex-1 truncate">
                    <span className={cn(m.unread && "font-bold")}>{m.subject}</span>
                    <span className="text-[#5f6368]"> - {m.snippet}</span>
                  </span>
                  <span className={cn("shrink-0 text-[11.5px]", m.unread ? "font-bold" : "text-[#5f6368]")}>{m.time}</span>
                </li>
              ))}
            </ul>
          </div>
        </div>

        <div className="absolute inset-x-2 top-2 bottom-0 flex flex-col overflow-hidden rounded-t-xl bg-white shadow-[0_8px_30px_rgba(0,0,0,0.22),0_0_0_1px_rgba(0,0,0,0.04)] @min-[520px]:inset-x-auto @min-[520px]:right-4 @min-[520px]:left-auto @min-[520px]:w-[min(430px,70%)]">
          <div className="flex h-9 shrink-0 items-center gap-3.5 bg-[#f2f6fc] pr-3 pl-4 font-medium text-[#041e49]">
            <span className="flex-1">New Message</span>
            <Minus size={15} strokeWidth={2} className="text-[#444746]" />
            <Maximize2 size={13} strokeWidth={2} className="text-[#444746]" />
            <X size={15} strokeWidth={2} className="text-[#444746]" />
          </div>
          <div className="mx-4 flex h-8 shrink-0 items-center gap-2 border-b border-black/10">
            <span className="text-[#444746]">To</span>
            <span className="flex h-6 items-center gap-1.5 rounded-full border border-black/15 pr-2 pl-0.5 text-[12.5px]">
              <Initials name="Daniel Okafor" className="size-5 rounded-full bg-[#e8710a] text-[9px]" />
              Daniel Okafor
              <X size={11} strokeWidth={2} className="text-black/50" />
            </span>
            <span className="ml-auto text-[12px] text-[#444746]">Cc Bcc</span>
          </div>
          <div className="mx-4 flex h-8 shrink-0 items-center border-b border-black/10">Re: Following up from Tuesday</div>
          <div className="min-h-0 flex-1 overflow-hidden px-4 pt-2 leading-[1.4] whitespace-pre-wrap">
            <FieldText typed={body} placeholder="" caret="bg-black" />
          </div>
          <div className="flex h-12 shrink-0 items-center gap-3.5 px-4 text-[#444746]">
            <span className="flex h-9 items-center rounded-full bg-[#0b57d0] font-medium text-white">
              <span className="pr-3 pl-5">Send</span>
              <span className="flex h-full items-center border-l border-white/30 pr-2.5 pl-2">
                <ChevronDown size={15} strokeWidth={2} />
              </span>
            </span>
            <Type size={16} strokeWidth={1.75} />
            <Paperclip size={16} strokeWidth={1.75} />
            <Link size={16} strokeWidth={1.75} className="hidden @min-[520px]:block" />
            <Smile size={16} strokeWidth={1.75} className="hidden @min-[520px]:block" />
            <ImageIcon size={16} strokeWidth={1.75} className="hidden @min-[520px]:block" />
            <PenLine size={16} strokeWidth={1.75} className="hidden @min-[640px]:block" />
            <EllipsisVertical size={16} strokeWidth={1.75} />
            <Trash2 size={16} strokeWidth={1.75} className="ml-auto" />
          </div>
        </div>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ WhatsApp */
// The 2026 WhatsApp for Mac: a floating sidebar, the Chats list with filter
// chips, the doodle wallpaper, and floating glass controls.

const WA_DOODLES = `url("data:image/svg+xml,${encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120" fill="none" stroke="#7d6f5c" stroke-opacity=".11" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><circle cx="18" cy="20" r="7"/><path d="M60 12l3 6 6 1-4.5 4 1 6-5.5-3-5.5 3 1-6L51 19l6-1z"/><path d="M98 22c-3-5-11-2-8 4l8 8 8-8c3-6-5-9-8-4z"/><path d="M14 70c4-6 10-6 14 0s10 6 14 0"/><rect x="56" y="58" width="16" height="12" rx="3"/><path d="M60 58v-3h8v3"/><path d="M92 62v14m0-14l10-3v14"/><circle cx="90" cy="77" r="3"/><circle cx="100" cy="74" r="3"/><path d="M20 102l8-8 8 8-8 8z"/><path d="M62 98c0-5 8-5 8 0s8 5 8 0"/><circle cx="104" cy="104" r="5"/></svg>',
)}")`;

const WA_CHATS = [
  { name: "Family", preview: "Mum: I'm doing the roast, someone bring dessert", time: "12:41", unread: 2, color: "bg-[#25d366]" },
  { name: "Lily", preview: "lol same", time: "11:02", unread: 0, color: "bg-[#a389f4]" },
  { name: "Five-a-side", preview: "Ben: who's in for Thursday?", time: "Yesterday", unread: 0, color: "bg-[#f7a33b]" },
  { name: "Ben Carter", preview: "🎤 Voice message (0:42)", time: "Yesterday", unread: 0, color: "bg-[#53bdeb]" },
  { name: "Aisha", preview: "Thank you!! See you then", time: "Monday", unread: 0, color: "bg-[#ff7a8a]" },
];

const WA_NAV = [
  [MessageCircle, "Chats"],
  [CircleDashed, "Updates"],
  [Phone, "Calls"],
  [ImageIcon, "Media"],
  [Archive, "Archived"],
  [Star, "Starred"],
] as const;

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
        "relative max-w-[82%] rounded-[10px] px-2.5 pt-1.5 pb-1 leading-[1.4] break-words shadow-[0_1px_0.5px_rgba(11,20,26,0.13)]",
        me ? "self-end rounded-tr-none bg-[#d9fdd3]" : "self-start rounded-tl-none bg-white",
        className,
      )}
    >
      <svg
        aria-hidden="true"
        viewBox="0 0 8 13"
        className={cn("absolute top-0 h-[13px] w-[8px]", me ? "-right-[7px] -scale-x-100 text-[#d9fdd3]" : "-left-[7px] text-white")}
      >
        <path d="M8 0H1.5C.4 0-.2 1.3.6 2.1L8 11z" fill="currentColor" />
      </svg>
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
    <div className="flex h-full bg-[#f4f4f4] text-[13px] text-[#111b21]">
      {/* Floating sidebar, collapsed to icons at this window width. */}
      <aside className="m-1.5 mr-0 hidden w-[62px] shrink-0 flex-col items-center rounded-2xl border border-black/5 bg-white/85 py-3 shadow-[0_2px_10px_rgba(0,0,0,0.06)] @min-[520px]:flex">
        <Lights className="mb-4 scale-[0.85]" />
        {WA_NAV.map(([Icon, label], i) => (
          <span
            key={label}
            title={label}
            className={cn("mb-1 grid size-9 place-items-center rounded-xl text-[#54656f]", i === 0 && "bg-black/6 text-[#111b21]")}
          >
            <Icon size={18} strokeWidth={1.75} />
          </span>
        ))}
        <Initials name="You" className="mt-auto size-7 rounded-full bg-[#25d366] text-[10px]" />
      </aside>

      <div className="hidden w-[212px] shrink-0 flex-col bg-white @min-[520px]:flex">
        <div className="flex h-12 shrink-0 items-center justify-between px-3">
          <span className="grid size-7 place-items-center rounded-full bg-black/5 text-[#54656f]">
            <Ellipsis size={15} strokeWidth={2} />
          </span>
          <span className="text-[14px] font-bold">Chats</span>
          <span className="grid size-7 place-items-center rounded-full bg-[#21c063] text-white">
            <Plus size={16} strokeWidth={2.5} />
          </span>
        </div>
        <div className="mx-3 flex h-8 items-center gap-2 rounded-lg bg-black/5 px-2.5 text-[12px] text-black/45">
          <Search size={13} strokeWidth={2} className="shrink-0" />
          <span className="truncate">Search</span>
        </div>
        <div className="mt-2.5 flex gap-1.5 px-3 text-[11.5px]">
          <span className="rounded-full bg-[#d9fdd3] px-2.5 py-1 font-medium text-[#0b6e2e]">All</span>
          <span className="rounded-full border border-black/10 px-2.5 py-1 text-[#54656f]">Unread</span>
          <span className="rounded-full border border-black/10 px-2.5 py-1 text-[#54656f]">Groups</span>
        </div>
        <ul className="mt-2 flex flex-col px-1.5">
          {WA_CHATS.map((c, i) => (
            <li key={c.name} className={cn("flex gap-2.5 rounded-xl px-2 py-2", i === 0 && "bg-black/5")}>
              <Initials name={c.name} className={cn("size-10 rounded-full text-[13px]", c.color)} />
              <div className="min-w-0 flex-1">
                <div className="flex items-baseline justify-between gap-1">
                  <span className="truncate text-[13px] font-semibold">{c.name}</span>
                  <span className={cn("shrink-0 text-[10.5px]", c.unread ? "font-medium text-[#1fa855]" : "text-black/45")}>
                    {c.time}
                  </span>
                </div>
                <div className="flex items-center gap-1">
                  <p className="min-w-0 flex-1 truncate text-[12px] text-black/50">{c.preview}</p>
                  {c.unread > 0 && (
                    <span className="grid size-[18px] shrink-0 place-items-center rounded-full bg-[#21c063] text-[10px] font-semibold text-white">
                      {c.unread}
                    </span>
                  )}
                </div>
              </div>
            </li>
          ))}
        </ul>
      </div>

      <section className="relative flex min-w-0 flex-1 flex-col bg-[#efeae2]" style={{ backgroundImage: WA_DOODLES }}>
        <header className="flex shrink-0 items-center gap-2.5 px-3 pt-2.5 pb-1.5">
          <Lights className="mr-1 @min-[520px]:hidden" />
          <Initials name="Family" className="size-8 rounded-full bg-[#25d366] text-[12px]" />
          <div className="min-w-0 flex-1 leading-[1.25]">
            <div className="font-semibold">Family</div>
            <div className="truncate text-[11.5px] text-black/50">Dad, Mum, Lily, You</div>
          </div>
          <span className="flex items-center gap-3.5 rounded-full border border-black/5 bg-white/85 px-3.5 py-1.5 text-[#54656f] shadow-[0_1px_6px_rgba(0,0,0,0.08)]">
            <Video size={17} strokeWidth={1.6} />
            <Phone size={15} strokeWidth={1.6} />
            <Ellipsis size={16} strokeWidth={1.75} />
          </span>
        </header>

        <div className="flex min-h-0 flex-1 flex-col justify-end gap-1.5 overflow-hidden px-5 pb-2.5 *:shrink-0">
          <span className="mb-1 self-center rounded-lg bg-white px-2.5 py-1 text-[11px] font-medium text-black/55 shadow-[0_1px_0.5px_rgba(11,20,26,0.13)]">
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

        <footer className="flex shrink-0 items-end gap-2 px-3 pb-3 text-[#54656f]">
          <span className="grid size-9 shrink-0 place-items-center rounded-full border border-black/5 bg-white/85 shadow-[0_1px_6px_rgba(0,0,0,0.08)]">
            <Plus size={19} strokeWidth={1.75} />
          </span>
          <div className="flex min-h-9 flex-1 items-end gap-2 rounded-[18px] border border-black/5 bg-white/90 py-2 pr-2.5 pl-3.5 leading-[1.4] text-[#111b21] shadow-[0_1px_6px_rgba(0,0,0,0.08)]">
            <div className="min-w-0 flex-1 break-words">
              <FieldText typed={typed} placeholder="" caret="bg-[#00a884]" />
            </div>
            <Smile size={18} strokeWidth={1.6} className="shrink-0 text-black/50" />
          </div>
          {typed ? (
            <span className="grid size-9 shrink-0 place-items-center rounded-full bg-[#21c063] text-white">
              <SendHorizontal size={16} strokeWidth={2} />
            </span>
          ) : (
            <Mic size={20} strokeWidth={1.75} className="mb-2 shrink-0" />
          )}
        </footer>
      </section>
    </div>
  );
}

/* --------------------------------------------------------------------- Slack */
// Slack's desktop app in the default Aubergine theme: the workspace rail,
// the channel sidebar, channel tabs, and the composer.

const SLACK_RAIL = [
  [House, "Home"],
  [MessagesSquare, "DMs"],
  [Bell, "Activity"],
  [Bookmark, "Later"],
  [Ellipsis, "More"],
] as const;

const SLACK_CHANNELS = [
  { name: "general", unread: false },
  { name: "launch", unread: false },
  { name: "eng", unread: true },
  { name: "random", unread: false },
];

function SlackMessage({ name, color, time, children, reactions, className }: {
  name: string;
  color: string;
  time: string;
  children: ReactNode;
  reactions?: [string, number][];
  className?: string;
}) {
  return (
    <div className={cn("flex gap-2.5", className)}>
      <Initials name={name} className={cn("size-9 rounded-lg text-[12px]", color)} />
      <div className="min-w-0 flex-1 leading-[1.46]">
        <div className="flex items-baseline gap-2">
          <span className="font-black">{name}</span>
          <span className="text-[11.5px] text-[#616061]">{time}</span>
        </div>
        <p className="break-words">{children}</p>
        {reactions && (
          <div className="mt-1 flex gap-1">
            {reactions.map(([emoji, n]) => (
              <span key={emoji} className="flex h-6 items-center gap-1 rounded-full border border-black/8 bg-[#f8f8f8] px-2 text-[11.5px] text-[#1d1c1d]">
                {emoji} {n}
              </span>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

export function SlackMock({ text, d }: MockProps) {
  const typed = typedText(text, d);
  const sent = d.phase === "sent";

  return (
    <div className="flex h-full flex-col bg-linear-to-b from-[#481a4b] to-[#3a0d3c] text-[13.5px] text-[#1d1c1d]">
      <div className="flex h-[38px] shrink-0 items-center gap-3 px-3.5 text-white/75">
        <Lights />
        <span className="ml-4 hidden items-center gap-3 @min-[520px]:flex">
          <ArrowLeft size={15} strokeWidth={2} />
          <ArrowRight size={15} strokeWidth={2} className="text-white/35" />
          <Clock size={14} strokeWidth={2} />
        </span>
        <div className="mx-auto flex h-[26px] w-full max-w-[300px] items-center gap-2 rounded-md bg-white/20 px-2.5 text-[12px] text-white/85">
          <Search size={13} strokeWidth={2} />
          Search Acme
        </div>
        <CircleHelp size={15} strokeWidth={2} className="shrink-0" />
      </div>

      <div className="flex min-h-0 flex-1">
        <nav className="hidden w-[60px] shrink-0 flex-col items-center gap-2.5 pt-1 pb-3 text-white @min-[520px]:flex">
          <span className="relative mb-1 grid size-9 place-items-center rounded-lg bg-[#dcbfe0] text-[15px] font-black text-[#4a154b]">
            A
          </span>
          {SLACK_RAIL.map(([Icon, label], i) => (
            <span key={label} className="flex flex-col items-center gap-0.5 text-[9.5px] font-semibold">
              <span className={cn("relative grid size-8 place-items-center rounded-lg", i === 0 && "bg-white/20")}>
                <Icon size={17} strokeWidth={1.9} />
                {label === "Activity" && (
                  <span className="absolute -top-1 -right-1 grid size-[15px] place-items-center rounded-full bg-[#cd2553] text-[9px]">3</span>
                )}
              </span>
              {label}
            </span>
          ))}
          <span className="mt-auto grid size-7 place-items-center rounded-full bg-white/20">
            <Plus size={15} strokeWidth={2} />
          </span>
          <Initials name="Alex Kim" className="size-8 rounded-lg bg-[#5b8def] text-[11px]" />
        </nav>

        <aside className="hidden w-[184px] shrink-0 flex-col rounded-tl-lg bg-[#5b2b5d]/55 pt-2 text-[#f4ecf5]/80 @min-[520px]:flex">
          <div className="flex h-9 items-center gap-1 px-3.5 text-[15.5px] font-black text-white">
            Acme <ChevronDown size={14} strokeWidth={2.5} />
            <SquarePen size={15} strokeWidth={2} className="ml-auto text-white/80" />
          </div>
          {[
            [MessageSquare, "Threads"],
            [Headphones, "Huddles"],
            [SendHorizontal, "Drafts & sent"],
          ].map(([Icon, label]) => {
            const I = Icon as typeof MessageSquare;
            return (
              <span key={label as string} className="mx-2 flex h-7 items-center gap-2 px-2">
                <I size={14} strokeWidth={2} />
                {label as string}
              </span>
            );
          })}
          <div className="mt-3 flex items-center gap-1 px-4 pb-1 text-[12.5px]">
            <ChevronDown size={12} strokeWidth={2.5} />
            Channels
          </div>
          {SLACK_CHANNELS.map((c) => (
            <span
              key={c.name}
              className={cn(
                "mx-2 flex h-7 items-center gap-1.5 rounded-md px-2",
                c.name === "launch" && "bg-[#f9edff] font-semibold text-[#39063a]",
                c.unread && "font-black text-white",
              )}
            >
              <Hash size={13} strokeWidth={2} />
              {c.name}
            </span>
          ))}
          <div className="mt-3 flex items-center gap-1 px-4 pb-1 text-[12.5px]">
            <ChevronDown size={12} strokeWidth={2.5} />
            Direct messages
          </div>
          {["Priya Shah", "Tom Becker"].map((n, i) => (
            <span key={n} className="mx-2 flex h-7 items-center gap-2 px-2">
              <span className="relative">
                <Initials name={n} className={cn("size-[18px] rounded text-[8px]", i === 0 ? "bg-[#e8912d]" : "bg-[#2bac76]")} />
                <span className="absolute -right-0.5 -bottom-0.5 size-[7px] rounded-full bg-[#2bac76] ring-2 ring-[#4d1f50]" />
              </span>
              {n}
            </span>
          ))}
        </aside>

        <section className="flex min-w-0 flex-1 flex-col overflow-hidden bg-white @min-[520px]:rounded-tl-lg">
          <header className="flex h-11 shrink-0 items-center gap-1 px-4 text-[16px] font-black">
            <Hash size={16} strokeWidth={2.5} />
            launch
            <ChevronDown size={14} strokeWidth={2.5} className="text-black/50" />
            <span className="ml-auto flex items-center gap-2 text-[12px] font-normal text-[#1d1c1d]">
              <span className="hidden h-7 items-center gap-1 rounded-md border border-black/15 px-1.5 @min-[640px]:flex">
                <Headphones size={14} strokeWidth={2} />
                <ChevronDown size={11} strokeWidth={2} />
              </span>
              <span className="flex h-7 items-center gap-1 rounded-md border border-black/15 px-1.5">
                <User size={13} strokeWidth={2} />
                12
              </span>
              <EllipsisVertical size={15} strokeWidth={2} />
            </span>
          </header>
          <div className="flex h-8 shrink-0 items-end gap-4 border-b border-black/10 px-4 text-[12.5px] text-[#616061]">
            <span className="flex items-center gap-1.5 border-b-2 border-[#611f69] pb-1.5 font-semibold text-[#1d1c1d]">
              <MessageSquare size={13} strokeWidth={2} />
              Messages
            </span>
            <span className="flex items-center gap-1.5 pb-1.5">
              <Folder size={13} strokeWidth={2} />
              Files
            </span>
            <Plus size={14} strokeWidth={2} className="mb-1.5" />
          </div>

          <div className="flex min-h-0 flex-1 flex-col justify-end gap-3.5 overflow-hidden px-4 pb-3 *:shrink-0">
            <SlackMessage name="Tom Becker" color="bg-[#2bac76]" time="9:48 AM">
              Show HN post is in the doc, shout if anything reads weird 🙏
            </SlackMessage>
            <SlackMessage
              name="Priya Shah"
              color="bg-[#e8912d]"
              time="10:02 AM"
              reactions={[
                ["🚀", 3],
                ["👀", 1],
              ]}
            >
              Are we good for tomorrow? Last time we hit the front page the waitlist fell over 😅
            </SlackMessage>
            {sent && (
              <SlackMessage name="Alex Kim" color="bg-[#5b8def]" time="10:06 AM" className="animate-[pop-in_280ms_ease-out]">
                {text}
              </SlackMessage>
            )}
          </div>

          <div className="mx-4 mb-3 shrink-0 rounded-lg border border-black/30">
            <div className="flex h-8 items-center gap-3.5 rounded-t-lg bg-[#f8f8f8] px-2.5 text-black/40">
              <Bold size={14} strokeWidth={2} />
              <Italic size={14} strokeWidth={2} />
              <Strikethrough size={14} strokeWidth={2} />
              <Link size={14} strokeWidth={2} />
              <ListOrdered size={14} strokeWidth={2} className="hidden @min-[520px]:block" />
              <List size={14} strokeWidth={2} className="hidden @min-[520px]:block" />
              <Code size={14} strokeWidth={2} className="hidden @min-[520px]:block" />
            </div>
            <div className="min-h-9 px-3 py-2 leading-[1.46] break-words">
              <FieldText typed={typed} placeholder="Message #launch" caret="bg-black" />
            </div>
            <div className="flex h-9 items-center gap-3.5 px-2.5 text-black/55">
              <span className="grid size-6 place-items-center rounded-full bg-black/6">
                <Plus size={15} strokeWidth={2} />
              </span>
              <ALargeSmall size={16} strokeWidth={1.75} />
              <Smile size={16} strokeWidth={1.75} />
              <AtSign size={16} strokeWidth={1.75} />
              <Video size={16} strokeWidth={1.75} className="hidden @min-[520px]:block" />
              <Mic size={16} strokeWidth={1.75} className="hidden @min-[520px]:block" />
              <span
                className={cn(
                  "ml-auto flex h-7 items-center rounded-md transition-colors",
                  typed ? "bg-[#007a5a] text-white" : "text-black/30",
                )}
              >
                <span className="px-2">
                  <SendHorizontal size={15} strokeWidth={2} />
                </span>
                <span className={cn("flex h-4 items-center border-l pr-1.5 pl-1", typed ? "border-white/40" : "border-black/15")}>
                  <ChevronDown size={12} strokeWidth={2} />
                </span>
              </span>
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------- Notion */
// Notion's desktop app with the classic sidebar (the 2026 one is opt-in).

const NOTION_PAGES = [
  ["📝", "Meeting notes"],
  ["🗺️", "Roadmap"],
  ["📈", "Investor updates"],
  ["🚀", "Launch retro"],
  ["📚", "Team wiki"],
];

export function NotionMock({ text, d }: MockProps) {
  const typed = typedText(text, d);

  return (
    <div className="flex h-full bg-white text-[13.5px] text-[#37352f]">
      <aside className="hidden w-[184px] shrink-0 flex-col border-r border-black/5 bg-[#f8f8f7] text-[12.5px] text-[#5f5e5b] @min-[520px]:flex">
        <div className="flex h-[38px] shrink-0 items-center gap-3 px-3.5 text-black/40">
          <Lights />
          <ChevronLeft size={15} strokeWidth={2} className="ml-auto" />
          <ChevronRight size={15} strokeWidth={2} className="text-black/20" />
        </div>
        <div className="flex h-8 items-center gap-2 px-3 font-medium text-[#37352f]">
          <span className="grid size-5 place-items-center rounded bg-[#e3e2e0] text-[10px] font-semibold text-[#37352f]">A</span>
          Acme
          <ChevronsUpDown size={11} strokeWidth={2} className="text-black/40" />
          <SquarePen size={15} strokeWidth={1.75} className="ml-auto text-black/45" />
        </div>
        {[
          [Search, "Search"],
          [House, "Home"],
          [AudioLines, "Meetings"],
          [Sparkles, "Notion AI"],
          [Inbox, "Inbox"],
        ].map(([Icon, label]) => {
          const I = Icon as typeof Search;
          return (
            <span key={label as string} className="flex h-7 items-center gap-2 px-3.5">
              <I size={14} strokeWidth={1.75} />
              {label as string}
            </span>
          );
        })}
        <div className="mt-3 px-3.5 pb-1 text-[11.5px] font-medium text-black/40">Teamspaces</div>
        {NOTION_PAGES.map(([icon, name]) => (
          <span
            key={name}
            className={cn(
              "mx-1.5 flex h-7 items-center gap-2 rounded-md px-2",
              name === "Launch retro" && "bg-black/5 font-medium text-[#37352f]",
            )}
          >
            <span className="w-4 text-center text-[13px]">{icon}</span>
            {name}
          </span>
        ))}
        <div className="mt-auto flex flex-col pb-2">
          <span className="flex h-7 items-center gap-2 px-3.5">
            <Settings size={14} strokeWidth={1.75} />
            Settings
          </span>
          <span className="flex h-7 items-center gap-2 px-3.5">
            <Trash2 size={14} strokeWidth={1.75} />
            Trash
          </span>
        </div>
      </aside>

      <section className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-[38px] shrink-0 items-center gap-1.5 px-3.5 text-[12.5px]">
          <Lights className="mr-2 @min-[520px]:hidden" />
          <span className="truncate text-black/50">📝 Meeting notes</span>
          <span className="text-black/30">/</span>
          <span className="truncate">🚀 Launch retro</span>
          <span className="ml-auto flex items-center gap-3.5 pl-2 text-black/50">
            <span className="hidden text-[#37352f] @min-[520px]:inline">Share</span>
            <MessageSquare size={15} strokeWidth={1.75} />
            <Star size={15} strokeWidth={1.75} />
            <Ellipsis size={16} strokeWidth={1.75} />
          </span>
        </header>

        {/* Top-aligned while the page fits, then pinned to the bottom, the way Notion scrolls to keep the caret in view. */}
        <div className="flex min-h-0 flex-1 flex-col justify-end overflow-hidden">
          <div className="shrink-0 grow px-[clamp(20px,8%,56px)] pt-6 pb-5 leading-[1.55]">
            <div className="text-[38px] leading-none">🚀</div>
            <h3 className="mt-3 text-[28px] leading-[1.2] font-bold tracking-[-0.01em]">Launch retro</h3>
            <div className="mt-3 flex items-center gap-2 text-[12.5px]">
              <span className="flex w-[84px] items-center gap-1.5 text-black/45">
                <Calendar size={13} strokeWidth={1.75} />
                Date
              </span>
              <span>October 2, 2026</span>
            </div>
            <div className="mt-1 flex items-center gap-2 text-[12.5px]">
              <span className="flex w-[84px] items-center gap-1.5 text-black/45">
                <Users size={13} strokeWidth={1.75} />
                Team
              </span>
              <span className="rounded bg-[#d3e5ef] px-1.5 text-[#183347]">Growth</span>
            </div>
            <div className="mt-4 h-px bg-black/8" />

            <h4 className="mt-4 text-[18px] font-semibold">What went well</h4>
            <ul className="mt-1 list-disc pl-5 marker:text-[#37352f]">
              <li>Front page of Hacker News for most of the day.</li>
              <li>About 2,400 waitlist signups, and the site stayed up.</li>
            </ul>

            <h4 className="mt-4 text-[18px] font-semibold">Next sprint</h4>
            <p className="mt-1 break-words">
              <FieldText typed={typed} placeholder="Write, press 'space' for AI, '/' for commands…" caret="bg-[#37352f]" />
            </p>
          </div>
        </div>
      </section>
    </div>
  );
}
