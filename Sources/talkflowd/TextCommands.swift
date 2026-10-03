import Foundation

/// Voice-command text transforms: spoken punctuation, emoji and paragraph breaks
/// (numbered lists live in `ListFormat`). Applied once by `Dictation`, to the complete transcript, before any
/// of it reaches the screen - so a rule is always deciding against the whole
/// sentence rather than against a fragment that happened to arrive together.
enum TextCommands {
    /// Spoken name -> symbol, for the "<name> emoji" command. Keys must be
    /// lowercase. Multi-word keys are matched before shorter ones that are a
    /// suffix of them (see `emojiPattern`), so "red heart emoji" beats "heart".
    static let emojiMap: [String: String] = [
        // hearts + affection
        "red heart": "❤️", "heart": "❤️", "blue heart": "💙", "green heart": "💚",
        "yellow heart": "💛", "orange heart": "🧡", "purple heart": "💜",
        "black heart": "🖤", "white heart": "🤍", "brown heart": "🤎",
        "broken heart": "💔", "sparkling heart": "💖", "growing heart": "💗",
        "beating heart": "💓", "revolving hearts": "💞", "two hearts": "💕",
        "heart exclamation": "❣️", "love letter": "💌", "kiss mark": "💋",
        "kiss": "😘", "love": "😍", "hug": "🤗", "cupid": "💘",

        // faces
        "grinning face": "😀", "grin": "😁", "smiley face": "😊", "smiling face": "😊",
        "happy face": "😊", "smile": "😊", "smiley": "😊", "blush": "☺️",
        "sweat smile": "😅", "laughing": "😂", "crying laughing": "😂", "rofl": "🤣",
        "rolling on the floor": "🤣", "upside down face": "🙃", "melting face": "🫠",
        "wink": "😉", "yum": "😋", "tongue out": "😛", "silly face": "🤪",
        "money face": "🤑", "hugging face": "🤗", "shushing face": "🤫",
        "thinking": "🤔", "thinking face": "🤔", "zipper face": "🤐",
        "raised eyebrow": "🤨", "neutral face": "😐", "expressionless": "😑",
        "no mouth": "😶", "smirk": "😏", "unamused": "😒", "rolling eyes": "🙄",
        "grimace": "😬", "lying face": "🤥", "relieved face": "😌", "pensive": "😔",
        "sleepy face": "😪", "drooling": "🤤", "sleeping face": "😴",
        "mask face": "😷", "sick face": "🤒", "nauseated": "🤢", "vomiting": "🤮",
        "sneezing": "🤧", "hot face": "🥵", "cold face": "🥶", "woozy": "🥴",
        "dizzy face": "😵", "exploding head": "🤯", "mind blown": "🤯",
        "cowboy": "🤠", "partying face": "🥳", "disguised face": "🥸",
        "cool": "😎", "sunglasses": "😎", "nerd face": "🤓", "monocle": "🧐",
        "confused face": "😕", "worried face": "😟", "frowning face": "🙁",
        "astonished": "😲", "flushed face": "😳", "pleading face": "🥺",
        "fearful": "😨", "anxious face": "😰", "crying": "😢", "sad": "😢",
        "loudly crying": "😭", "sobbing": "😭", "screaming": "😱",
        "confounded": "😖", "persevering": "😣", "disappointed face": "😞",
        "weary face": "😩", "tired face": "😫", "yawning face": "🥱",
        "triumph": "😤", "pouting face": "😡", "angry": "😠", "angry face": "😠",
        "cursing face": "🤬", "smiling devil": "😈", "devil": "👿", "clown": "🤡",
        "ogre": "👹", "goblin": "👺", "alien": "👽", "robot": "🤖",
        "skull": "💀", "ghost": "👻", "poop": "💩",
        "smiling cat": "😸", "heart eyes cat": "😻", "crying cat": "😿",
        "heart eyes": "😍", "star struck": "🤩",

        // hands + body
        "thumbs up": "👍", "thumbs down": "👎", "clap": "👏", "wave": "👋",
        "waving hand": "👋", "raised hand": "✋", "vulcan salute": "🖖",
        "ok hand": "👌", "pinch": "🤏", "victory hand": "✌️", "peace sign": "✌️",
        "crossed fingers": "🤞", "love you gesture": "🤟", "horns": "🤘",
        "call me hand": "🤙", "point left": "👈", "point right": "👉",
        "point up": "👆", "point down": "👇", "middle finger": "🖕",
        "raised fist": "✊", "fist bump": "👊", "open hands": "👐",
        "palms up": "🤲", "handshake": "🤝", "folded hands": "🙏", "pray": "🙏",
        "writing hand": "✍️", "nail polish": "💅", "selfie": "🤳",
        "muscle": "💪", "flexed biceps": "💪", "brain": "🧠", "tooth": "🦷",
        "bone": "🦴", "eye": "👁️", "eyes": "👀", "tongue": "👅", "ear": "👂",
        "nose": "👃", "footprints": "👣", "high five": "🙌", "raised hands": "🙌",
        "shrug": "🤷", "person shrugging": "🤷", "facepalm": "🤦",

        // people
        "baby": "👶", "police officer": "👮", "detective": "🕵️",
        "construction worker": "👷", "prince": "🤴", "princess": "👸",
        "ninja": "🥷", "santa": "🎅", "superhero": "🦸", "supervillain": "🦹",
        "mage": "🧙", "wizard": "🧙", "fairy": "🧚", "vampire": "🧛",
        "mermaid": "🧜", "elf": "🧝", "zombie": "🧟", "dancer": "💃",
        "dancing man": "🕺", "running": "🏃", "walking": "🚶", "swimming": "🏊",
        "surfing": "🏄", "biking": "🚴", "climbing": "🧗",
        "lifting weights": "🏋️", "yoga": "🧘",

        // animals
        "dog": "🐶", "cat": "🐱", "monkey": "🐵", "see no evil": "🙈",
        "hear no evil": "🙉", "speak no evil": "🙊", "gorilla": "🦍",
        "wolf": "🐺", "fox": "🦊", "raccoon": "🦝", "lion": "🦁", "tiger": "🐯",
        "horse": "🐴", "unicorn": "🦄", "zebra": "🦓", "deer": "🦌", "cow": "🐮",
        "pig": "🐷", "ram": "🐏", "sheep": "🐑", "goat": "🐐", "camel": "🐫",
        "llama": "🦙", "giraffe": "🦒", "elephant": "🐘", "rhino": "🦏",
        "hippo": "🦛", "mouse": "🐭", "hamster": "🐹", "rabbit": "🐰",
        "bunny": "🐰", "hedgehog": "🦔", "bear": "🐻", "koala": "🐨",
        "panda": "🐼", "sloth": "🦥", "otter": "🦦", "kangaroo": "🦘",
        "turkey": "🦃", "chicken": "🐔", "rooster": "🐓", "baby chick": "🐤",
        "bird": "🐦", "penguin": "🐧", "dove": "🕊️", "eagle": "🦅", "duck": "🦆",
        "swan": "🦢", "owl": "🦉", "flamingo": "🦩", "peacock": "🦚",
        "parrot": "🦜", "frog": "🐸", "crocodile": "🐊", "turtle": "🐢",
        "lizard": "🦎", "snake": "🐍", "dragon": "🐲", "dinosaur": "🦕",
        "t rex": "🦖", "whale": "🐳", "dolphin": "🐬", "fish": "🐟",
        "tropical fish": "🐠", "blowfish": "🐡", "shark": "🦈", "octopus": "🐙",
        "snail": "🐌", "butterfly": "🦋", "bug": "🐛", "ant": "🐜", "bee": "🐝",
        "ladybug": "🐞", "cricket": "🦗", "spider": "🕷️", "spider web": "🕸️",
        "scorpion": "🦂", "mosquito": "🦟", "microbe": "🦠", "paw prints": "🐾",

        // plants + weather + sky
        "bouquet": "💐", "cherry blossom": "🌸", "rose": "🌹", "wilted rose": "🥀",
        "hibiscus": "🌺", "sunflower": "🌻", "blossom": "🌼", "tulip": "🌷",
        "seedling": "🌱", "evergreen tree": "🌲", "tree": "🌳", "palm tree": "🌴",
        "cactus": "🌵", "herb": "🌿", "four leaf clover": "🍀", "clover": "🍀",
        "maple leaf": "🍁", "fallen leaf": "🍂", "leaves": "🍃",
        "sun": "☀️", "sunny": "☀️", "sun with face": "🌞", "cloud": "☁️",
        "partly cloudy": "⛅", "rain": "🌧️", "thunderstorm": "⛈️",
        "lightning": "⚡", "high voltage": "⚡", "tornado": "🌪️", "fog": "🌫️",
        "wind": "🌬️", "cyclone": "🌀", "rainbow": "🌈", "umbrella": "☂️",
        "umbrella rain": "☔", "snowflake": "❄️", "snowman": "⛄",
        "comet": "☄️", "fire": "🔥", "droplet": "💧", "water": "💧",
        "sweat drops": "💦", "ocean wave": "🌊", "wave water": "🌊",
        "moon": "🌙", "crescent moon": "🌙", "full moon": "🌕", "new moon": "🌑",
        "moon face": "🌝", "star": "⭐", "glowing star": "🌟",
        "shooting star": "🌠", "sparkles": "✨", "milky way": "🌌",
        "globe": "🌍", "earth": "🌍", "globe americas": "🌎", "globe asia": "🌏",

        // food + drink
        "grapes": "🍇", "melon": "🍈", "watermelon": "🍉", "tangerine": "🍊",
        "lemon": "🍋", "banana": "🍌", "pineapple": "🍍", "mango": "🥭",
        "apple": "🍎", "pear": "🍐", "peach": "🍑", "cherries": "🍒",
        "strawberry": "🍓", "blueberries": "🫐", "kiwi": "🥝", "tomato": "🍅",
        "olive": "🫒", "coconut": "🥥", "avocado": "🥑", "eggplant": "🍆",
        "potato": "🥔", "carrot": "🥕", "corn": "🌽", "hot pepper": "🌶️",
        "cucumber": "🥒", "broccoli": "🥦", "garlic": "🧄", "onion": "🧅",
        "mushroom": "🍄", "peanuts": "🥜", "bread": "🍞", "croissant": "🥐",
        "baguette": "🥖", "pretzel": "🥨", "bagel": "🥯", "pancakes": "🥞",
        "waffle": "🧇", "cheese": "🧀", "poultry leg": "🍗", "bacon": "🥓",
        "burger": "🍔", "hamburger": "🍔", "fries": "🍟", "pizza": "🍕",
        "hot dog": "🌭", "sandwich": "🥪", "taco": "🌮", "burrito": "🌯",
        "falafel": "🧆", "egg": "🥚", "cooking": "🍳", "salad": "🥗",
        "popcorn": "🍿", "butter": "🧈", "salt": "🧂", "bento": "🍱",
        "rice": "🍚", "curry": "🍛", "ramen": "🍜", "spaghetti": "🍝",
        "sushi": "🍣", "fried shrimp": "🍤", "dumpling": "🥟",
        "fortune cookie": "🥠", "takeout box": "🥡", "crab": "🦀",
        "lobster": "🦞", "shrimp": "🦐", "squid": "🦑", "oyster": "🦪",
        "ice cream": "🍦", "donut": "🍩", "cookie": "🍪", "cake": "🎂",
        "birthday cake": "🎂", "cupcake": "🧁", "pie": "🥧", "chocolate": "🍫",
        "candy": "🍬", "lollipop": "🍭", "honey": "🍯", "milk": "🥛",
        "coffee": "☕", "tea": "🍵", "sake": "🍶", "champagne": "🍾",
        "wine": "🍷", "cocktail": "🍸", "tropical drink": "🍹", "beer": "🍺",
        "beer mugs": "🍻", "clinking glasses": "🥂", "whiskey": "🥃",
        "cup with straw": "🥤", "bubble tea": "🧋", "ice": "🧊",
        "chopsticks": "🥢", "fork and knife": "🍴", "spoon": "🥄",

        // travel + places
        "world map": "🗺️", "compass": "🧭", "mountain": "⛰️", "volcano": "🌋",
        "camping": "🏕️", "beach": "🏖️", "desert": "🏜️", "island": "🏝️",
        "stadium": "🏟️", "castle": "🏰", "ferris wheel": "🎡",
        "roller coaster": "🎢", "carousel": "🎠", "fountain": "⛲", "tent": "⛺",
        "house": "🏠", "office building": "🏢", "hospital": "🏥", "bank": "🏦",
        "hotel": "🏨", "school": "🏫", "factory": "🏭", "church": "⛪",
        "mosque": "🕌", "synagogue": "🕍", "temple": "🛕",
        "statue of liberty": "🗽", "sunrise": "🌅", "sunset": "🌇",
        "night with stars": "🌃", "fireworks": "🎆", "sparkler": "🎇",
        "car": "🚗", "taxi": "🚕", "bus": "🚌", "ambulance": "🚑",
        "fire engine": "🚒", "police car": "🚓", "pickup truck": "🛻",
        "truck": "🚚", "tractor": "🚜", "scooter": "🛵", "motorcycle": "🏍️",
        "bicycle": "🚲", "skateboard": "🛹", "roller skate": "🛼",
        "wheelchair": "🦽", "train": "🚆", "metro": "🚇", "tram": "🚊",
        "bullet train": "🚄", "helicopter": "🚁", "airplane": "✈️",
        "departure": "🛫", "arrival": "🛬", "parachute": "🪂", "seat": "💺",
        "rocket": "🚀", "rocket ship": "🚀", "flying saucer": "🛸",
        "sailboat": "⛵", "speedboat": "🚤", "ship": "🚢", "ferry": "⛴️",
        "anchor": "⚓", "fuel pump": "⛽", "traffic light": "🚦",
        "construction sign": "🚧",

        // objects
        "watch": "⌚", "phone": "📱", "laptop": "💻", "computer": "💻",
        "keyboard": "⌨️", "printer": "🖨️", "joystick": "🕹️",
        "floppy disk": "💾", "abacus": "🧮", "movie camera": "🎥",
        "film": "🎞️", "projector": "📽️", "video camera": "📹",
        "camera": "📷", "magnifying glass": "🔍", "candle": "🕯️",
        "light bulb": "💡", "flashlight": "🔦", "lantern": "🏮",
        "book": "📖", "books": "📚", "notebook": "📓", "page": "📄",
        "newspaper": "📰", "bookmark": "🔖", "label": "🏷️", "pencil": "✏️",
        "pen": "🖊️", "paperclip": "📎", "scissors": "✂️", "clipboard": "📋",
        "calendar": "📅", "chart increasing": "📈", "chart decreasing": "📉",
        "bar chart": "📊", "money bag": "💰", "coin": "🪙", "dollar": "💵",
        "euro": "💶", "pound": "💷", "money with wings": "💸",
        "credit card": "💳", "receipt": "🧾", "gem": "💎", "diamond": "💎",
        "scales": "⚖️", "toolbox": "🧰", "magnet": "🧲", "hammer": "🔨",
        "axe": "🪓", "wrench": "🔧", "screwdriver": "🪛", "nut and bolt": "🔩",
        "gear": "⚙️", "chains": "⛓️", "bomb": "💣", "firecracker": "🧨",
        "knife": "🔪", "dagger": "🗡️", "swords": "⚔️", "shield": "🛡️",
        "coffin": "⚰️", "crystal ball": "🔮", "test tube": "🧪",
        "petri dish": "🧫", "dna": "🧬", "microscope": "🔬", "telescope": "🔭",
        "satellite": "📡", "syringe": "💉", "pill": "💊", "bandage": "🩹",
        "stethoscope": "🩺", "door": "🚪", "bed": "🛏️", "couch": "🛋️",
        "toilet": "🚽", "shower": "🚿", "bathtub": "🛁", "razor": "🪒",
        "sponge": "🧽", "soap": "🧼", "broom": "🧹", "basket": "🧺",
        "bucket": "🪣", "mirror": "🪞", "chair": "🪑", "shopping cart": "🛒",
        "shopping bags": "🛍️", "backpack": "🎒", "briefcase": "💼",
        "handbag": "👜", "purse": "👛", "glasses": "👓", "necktie": "👔",
        "shirt": "👕", "jeans": "👖", "scarf": "🧣", "gloves": "🧤",
        "coat": "🧥", "socks": "🧦", "dress": "👗", "high heel": "👠",
        "sneaker": "👟", "boot": "👢", "crown": "👑", "top hat": "🎩",
        "graduation cap": "🎓", "helmet": "⛑️", "ring": "💍",
        "lipstick": "💄", "key": "🔑", "lock": "🔒", "unlocked": "🔓",
        "envelope": "✉️", "inbox": "📥", "outbox": "📤", "package": "📦",
        "mailbox": "📫", "gift": "🎁", "balloon": "🎈", "confetti": "🎊",
        "party": "🎉", "tada": "🎉", "trophy": "🏆", "medal": "🏅",
        "first place": "🥇", "second place": "🥈", "third place": "🥉",
        "ticket": "🎫", "circus": "🎪", "performing arts": "🎭",
        "framed picture": "🖼️", "clapper board": "🎬", "art": "🎨",

        // sport + games
        "soccer ball": "⚽", "football": "🏈", "basketball": "🏀",
        "baseball": "⚾", "softball": "🥎", "tennis": "🎾", "volleyball": "🏐",
        "rugby": "🏉", "flying disc": "🥏", "bowling": "🎳",
        "field hockey": "🏑", "ice hockey": "🏒", "ping pong": "🏓",
        "badminton": "🏸", "boxing glove": "🥊", "martial arts": "🥋",
        "goal net": "🥅", "golf": "⛳", "ice skate": "⛸️", "fishing": "🎣",
        "diving mask": "🤿", "ski": "🎿", "sled": "🛷", "target": "🎯",
        "bullseye": "🎯", "kite": "🪁", "eight ball": "🎱",
        "slot machine": "🎰", "video game": "🎮", "dice": "🎲",
        "puzzle": "🧩", "teddy bear": "🧸", "playing cards": "🃏",

        // music
        "music note": "🎵", "musical notes": "🎶", "musical score": "🎼",
        "headphones": "🎧", "microphone": "🎤", "radio": "📻",
        "saxophone": "🎷", "trumpet": "🎺", "violin": "🎻", "guitar": "🎸",
        "drum": "🥁", "megaphone": "📣", "loudspeaker": "📢",
        "speaker": "🔊", "mute": "🔇", "bell": "🔔", "bell off": "🔕",

        // symbols
        "check mark": "✅", "checkmark": "✅", "check": "✅",
        "x mark": "❌", "cross mark": "❌", "hundred": "💯",
        "hundred points": "💯", "question mark": "❓",
        "exclamation mark": "❗", "warning": "⚠️", "no entry": "⛔",
        "prohibited": "🚫", "radioactive": "☢️", "biohazard": "☣️",
        "recycle": "♻️", "infinity": "♾️", "trident": "🔱",
        "peace symbol": "☮️", "yin yang": "☯️", "atom": "⚛️",
        "anger": "💢", "collision": "💥", "dizzy": "💫", "dash": "💨",
        "hole": "🕳️", "speech bubble": "💬", "thought bubble": "💭",
        "zzz": "💤", "clock": "🕐", "hourglass": "⏳", "alarm clock": "⏰",
        "stopwatch": "⏱️", "bridge": "🌉", "night bridge": "🌉", "flag": "🚩", "checkered flag": "🏁",
        "crossed flags": "🎌", "white flag": "🏳️", "rainbow flag": "🏳️‍🌈",
        "pirate flag": "🏴‍☠️", "plus": "➕", "minus": "➖", "divide": "➗",
        "arrow up": "⬆️", "arrow down": "⬇️", "arrow left": "⬅️",
        "arrow right": "➡️", "up arrow": "⬆️", "down arrow": "⬇️",
        "left arrow": "⬅️", "right arrow": "➡️", "repeat": "🔁",
        "shuffle": "🔀", "play button": "▶️", "pause button": "⏸️",
        "stop button": "⏹️", "record button": "⏺️", "fast forward": "⏩",
        "rewind": "⏪"
    ]

    /// Extra spellings that should resolve to a symbol already in the map. Whisper
    /// hears what it hears - "grown" for "groan" - and people say "sad face" for
    /// what the map calls "sad".
    private static let emojiAliases: [String: String] = [
        "groan": "weary face", "grown": "weary face", "moan": "weary face",
        "sad face": "crying", "crying face": "crying", "happy": "smiley face",
        "laugh": "laughing", "lol": "laughing", "smiling": "smiley face",
        "thumbs": "thumbs up", "thumb up": "thumbs up", "thumbs up sign": "thumbs up",
        "heart eyes face": "heart eyes", "hearts": "two hearts",
        "prayer hands": "folded hands", "praying hands": "folded hands",
        "flame": "fire", "flames": "fire", "hundred percent": "hundred",
        "tick": "check mark", "cross": "x mark", "exclamation point": "exclamation mark",
        "smiley face emoji": "smiley face", "grinning": "grinning face",
        "poop face": "poop", "hooray": "party",
        "celebrate": "party", "celebration": "party", "clapping": "clap",
        "clapping hands": "clap", "waving": "wave", "wink face": "wink",
        "angry face emoji": "angry", "shocked": "astonished", "surprised": "astonished",
        "sleepy": "sleepy face", "tired": "tired face", "sick": "sick face",
        "nervous": "anxious face", "worried": "worried face", "confused": "confused face"
    ]

    /// Captures up to three words before "emoji" and resolves them here rather
    /// than baking every accepted phrase into the pattern itself. The old pattern
    /// was an alternation of the literal dictionary keys, so anything not spelled
    /// exactly as a key - "bridge emoji", "groan emoji", "sad face emoji" - simply
    /// didn't match and the words were typed out literally.
    ///
    /// Trailing `[,.!?]?` matters too: whisper punctuates the phrase as ordinary
    /// speech ("water emoji."), and without eating that the symbol lands on screen
    /// as "💧 ."
    static let emojiPattern = try! NSRegularExpression(
        pattern: "\\b((?:[\\p{L}']+\\s+){0,2}[\\p{L}']+)\\s+emojis?\\b[,.!?]?\\s*",
        options: [.caseInsensitive]
    )

    /// Longest phrase first: for "red heart emoji" the three-word attempt fails,
    /// then "red heart" hits before the shorter "heart" ever gets a chance.
    /// Returns the symbol plus how many trailing words of `phrase` it consumed, so
    /// the caller can keep any leading words that weren't part of the name.
    static func resolveEmoji(phrase: String) -> (symbol: String, wordsUsed: Int)? {
        let words = phrase.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }

        for take in stride(from: min(3, words.count), through: 1, by: -1) {
            let candidate = words.suffix(take).joined(separator: " ")
            if let symbol = lookupEmoji(candidate) { return (symbol, take) }
        }
        return nil
    }

    private static func lookupEmoji(_ name: String) -> String? {
        if let symbol = emojiMap[name] { return symbol }
        if let aliased = emojiAliases[name], let symbol = emojiMap[aliased] { return symbol }
        // "smiling face emoji" -> "smiling face" is a key, but "cowboy face emoji"
        // is not; drop a trailing "face" and try the bare name.
        if name.hasSuffix(" face") {
            let bare = String(name.dropLast(5))
            if let symbol = emojiMap[bare] { return symbol }
            if let aliased = emojiAliases[bare], let symbol = emojiMap[aliased] { return symbol }
        }
        // Spoken plurals: "rockets emoji".
        if name.hasSuffix("s"), let symbol = emojiMap[String(name.dropLast())] { return symbol }
        return nil
    }

    static let newParagraphPattern = try! NSRegularExpression(
        pattern: "\\s*\\bnew paragraph\\b,?\\s*", options: [.caseInsensitive]
    )

    /// The whole transcript is formatted in one pass, so the paragraph rule only
    /// ever needs to know whether a break would land at the very start
    /// of the text (suppressed) or between words (a real separator). These used to
    /// take a `precededBy` argument for text already on screen ahead of this
    /// string; nothing ever passed one.
    static func applyAll(_ text: String) -> String {
        var result = applySpokenPunctuation(text)
        result = applyEmoji(result)
        result = applyParagraphBreaks(result)
        return result
    }

    /// Spoken punctuation: saying "comma" types "," rather than the word.
    ///
    /// Whisper has already punctuated the sentence as ordinary speech, so "Dear
    /// Sarah comma can you" arrives as "Dear Sarah, comma, can you" - the mark it
    /// guessed AND the word. Both have to collapse into one mark, which is why
    /// this strips any punctuation already sitting on either side of the command
    /// word instead of just substituting it.
    private static let spokenPunctuation: [String: String] = [
        "comma": ",", "period": ".", "full stop": ".", "question mark": "?",
        "exclamation mark": "!", "exclamation point": "!", "colon": ":",
        "semicolon": ";", "open paren": "(", "close paren": ")",
        "open parenthesis": "(", "close parenthesis": ")",
        "new line": "\n", "newline": "\n", "next line": "\n"
    ]

    private static let spokenPunctuationPattern: NSRegularExpression = {
        let keys = spokenPunctuation.keys.sorted { $0.count > $1.count }
        let alternation = keys.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // Also eats the punctuation whisper put before and after the spoken word.
        return try! NSRegularExpression(
            pattern: "\\s*[,.!?;:]*\\s*\\b(\(alternation))\\b[,.!?;:]*\\s*",
            options: [.caseInsensitive]
        )
    }()

    static func applySpokenPunctuation(_ text: String) -> String {
        let ns = text as NSString
        let matches = spokenPunctuationPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let mark = spokenPunctuation[key] ?? ""
            lastEnd = match.range.location + match.range.length

            // "new line" at the very start would only indent the insertion.
            if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, mark == "\n" { continue }
            result += mark
            if lastEnd < ns.length, mark != "\n" { result += " " }
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return result
    }

    /// A spoken "period" ends a sentence, and a spoken "new line"/"new paragraph"
    /// starts one, so the following word should be capitalised. Runs last, over
    /// the output of every transform, so all of them behave the same way.
    ///
    /// The FIRST word is deliberately left alone: a dictation frequently
    /// continues a sentence already on screen ("and then we left"), and forcing a
    /// capital there would be wrong more often than right. Whisper capitalises
    /// genuine sentence openings by itself.
    static func capitalizeAfterSentenceEnds(_ text: String) -> String {
        var characters = Array(text)
        var startOfSentence = false
        for index in characters.indices {
            let character = characters[index]
            if startOfSentence, character.isLetter {
                characters[index] = Character(character.uppercased())
                startOfSentence = false
            } else if ".!?\n".contains(character) {
                startOfSentence = true
            } else if !character.isWhitespace {
                startOfSentence = false
            }
        }
        return String(characters)
    }

    static func applyEmoji(_ text: String) -> String {
        let ns = text as NSString
        let matches = emojiPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = 0
        for match in matches {
            let phrase = ns.substring(with: match.range(at: 1))
            guard let hit = resolveEmoji(phrase: phrase) else { continue } // unknown name: leave the words alone

            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))

            // The capture greedily took up to three words; only the trailing ones
            // that actually named a symbol get replaced. "send the water emoji"
            // captures "send the water" but must only consume "water".
            let phraseWords = phrase.split(separator: " ").map(String.init)
            let kept = phraseWords.dropLast(hit.wordsUsed)
            if !kept.isEmpty { result += kept.joined(separator: " ") + " " }

            result += hit.symbol
            lastEnd = match.range.location + match.range.length
            // The pattern already ate any whitespace after the phrase, so re-add a
            // single space only when more text actually follows - otherwise a
            // message ending in an emoji gets a stray trailing space.
            if lastEnd < ns.length { result += " " }
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return result
    }

    static func applyParagraphBreaks(_ text: String) -> String {
        let ns = text as NSString
        let matches = newParagraphPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += "\n\n"
            }
            lastEnd = match.range.location + match.range.length
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return result
    }
}
