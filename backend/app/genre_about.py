"""Krátké české popisy hlavních žánrů (stránka žánru › O žánru). Last.fm
má popisy jen anglicky -- u podžánrů zůstávají, hlavní žánry mají vlastní."""

ABOUT_CS: dict[str, str] = {
    "pop": (
        "Populární hudba postavená na chytlavé melodii, refrénu a krátké stopáži. Od Beatles a Madonny přes "
        "Michaela Jacksona po Taylor Swift a Billie Eilish – pop si průběžně bere z rocku, elektroniky, R&B "
        "i hip hopu a podle toho, co zrovna zní nejvíc, se mění."
    ),
    "hiphop": (
        "Vznikl v 70. letech v Bronxu z DJských večírků, breakdance a rapu přes smyčky starších nahrávek. "
        "Od oldschoolu a boom bapu 90. let po trap, drill a introspektivní rap – dnes nejposlouchanější "
        "žánr světa a silná scéna i v Česku a na Slovensku."
    ),
    "rock": (
        "Kytary, basa, bicí a energie. Z rock'n'rollu 50. let vyrostl klasický rock 60. a 70. let (Beatles, "
        "Led Zeppelin, Pink Floyd), pak punk, grunge, britpop i alternativa. Pořád základ, ze kterého "
        "vychází spousta dalších žánrů."
    ),
    "indie": (
        "Původně hudba z nezávislých vydavatelství, dnes spíš zvuk a přístup: kytarové kapely, lo-fi, dream "
        "pop i písničkáři s osobním rukopisem. Od The Smiths a Pixies přes Arctic Monkeys po Phoebe Bridgers."
    ),
    "electronic": (
        "Hudba tvořená syntezátory, samplery a počítačem – od průkopníků Kraftwerk přes house, techno a "
        "drum'n'bass po ambient, IDM a synthwave. Někdy na tanec, jindy na poslech se sluchátky."
    ),
    "dance": (
        "Hudba stavěná pro taneční parket: disco, house, eurodance, trance i dnešní EDM. Pravidelný beat, "
        "budování napětí a drop – od klubů v Chicagu a Detroitu po velké festivaly."
    ),
    "rnb": (
        "Rhythm and blues vyrostl z gospelu a blues; dnešní R&B spojuje soulový zpěv s hip hopovými beaty "
        "a elektronikou. Od Motownu přes 90. léta (TLC, Aaliyah) po Franka Oceana a SZA."
    ),
    "jazz": (
        "Afroamerická hudba plná improvizace a swingu, zrozená v New Orleans na začátku 20. století. Big "
        "bandy, bebop, cool jazz, fusion i moderní jazz – Louis Armstrong, Miles Davis, John Coltrane."
    ),
    "classical": (
        "Evropská hudební tradice od baroka (Bach, Vivaldi) přes klasicismus (Mozart, Haydn) a romantismus "
        "(Beethoven, Dvořák, Smetana) po moderní a současnou vážnou hudbu. Orchestry, komorní soubory, opera "
        "i sólový klavír."
    ),
    "folk": (
        "Lidová a akustická hudba s důrazem na příběh a text. Od tradičních písní přes písničkáře 60. let "
        "(Bob Dylan, Joni Mitchell) po indie folk – a česká trampská a folková scéna od Porty po dnešek."
    ),
    "metal": (
        "Hlasité zkreslené kytary, rychlé bicí a síla. Z hard rocku 70. let (Black Sabbath) vyrostl heavy "
        "metal a z něj desítky odnoží – thrash, death, black, doom, metalcore i progresivní metal."
    ),
    "soul": (
        "Soul spojil gospel a rhythm and blues ve vášnivý zpěv (Aretha Franklin, Otis Redding, Marvin Gaye); "
        "funk z něj udělal rytmus a groove (James Brown, Parliament). Základ, ze kterého čerpá R&B i hip hop."
    ),
    "country": (
        "Hudba amerického venkova a Jihu – kytara, banjo, steel kytara, housle a příběhy o obyčejném životě. "
        "Od Johnnyho Cashe a Dolly Parton přes outlaw country po dnešní Nashville, americanu i country pop."
    ),
    "bluegrass": (
        "Akustická hudba Apalačských hor, kterou ve 40. letech zformoval Bill Monroe se svými Blue Grass Boys: "
        "banjo, mandolína, kytara, housle, kontrabas a dobro, rychlá sóla a vícehlasý zpěv. Od Flatta & "
        "Scruggse a Stanley Brothers přes newgrass (Sam Bush, Béla Fleck) po Billyho Stringse a Molly "
        "Tuttle – a silná česká scéna od Druhé trávy po Poutníky."
    ),
    "blues": (
        "Kořen většiny moderní hudby: dvanáctitaktové schéma, „modré“ tóny a výpověď o životě. Z delty "
        "Mississippi (Robert Johnson) přes elektrický Chicago blues (Muddy Waters, B.B. King) po blues rock."
    ),
    "reggae": (
        "Jamajská hudba s typickým offbeatem, basou v popředí a uvolněným tempem. Ze ska a rocksteady vyrostlo "
        "roots reggae Boba Marleyho, dub i dancehall."
    ),
    "latin": (
        "Hudba Latinské Ameriky a Karibiku: salsa, cumbia, bachata, tango, latin pop a hlavně reggaeton, "
        "který dnes vládne žebříčkům (Bad Bunny, Karol G)."
    ),
    "brazil": (
        "Brazilská hudba: samba z karnevalů, bossa nova (João Gilberto, Tom Jobim), tropicália, MPB i baile "
        "funk z favel."
    ),
    "african": (
        "Hudba celého kontinentu – afrobeat Fely Kutiho, highlife, pouštní blues Tuaregů, ethio-jazz a dnes "
        "hlavně nigerijské afrobeats a jihoafrické amapiano."
    ),
    "asian": (
        "Pop a rock z Asie: korejský K-pop s dokonalou produkcí a choreografií, japonský J-pop, J-rock a "
        "city pop 80. let, čínský C-pop i hudba z anime."
    ),
    "indian": (
        "Hudba Indie: bollywoodské filmové písně, klasická hindustánská a karnátská tradice (sitár, tabla), "
        "punjabský bhangra i súfijská hudba."
    ),
    "kids": "Písničky pro děti – na zpívání, tancování, učení i usínání.",
    # Nálady a chvíle
    "sleep": (
        "Hudba, u které se dobře usíná: pomalé tempo, žádné prudké změny hlasitosti, hodně prostoru a ticha. "
        "Ambient, klavír, drone a neoklasika – od Briana Ena a Maxe Richtera po Nilse Frahma."
    ),
    "focus": (
        "Na práci a učení: stálý rytmus, málo slov, nic, co by tahalo pozornost. Lo-fi, post-rock, minimal, "
        "neoklasika a ambient – a samozřejmě herní a filmové soundtracky."
    ),
    "chill": (
        "Pohodová hudba na odpočinek: lo-fi, downtempo, trip-hop a dream pop. Měkké beaty, teplý zvuk "
        "a nálada, při které se nikam nespěchá."
    ),
    "workout": (
        "Energie do posilovny a na běh: rychlé tempo, výrazný beat a gradace. EDM, trap, drum and bass, "
        "hard rock i metalcore – cokoli, co tě vyhecuje k dalšímu opakování."
    ),
    "party": (
        "Na tancování a večírky: house, disco, dance-pop a reggaeton. Refrény, které zná každý, a beat, "
        "u kterého se nedá stát."
    ),
    "feelgood": (
        "Hudba pro dobrou náladu: funk, disco, soul, indie pop a power pop – slunné melodie a rytmus, "
        "který zvedne den."
    ),
    "romance": (
        "Písně o lásce a na romantický večer: soul, R&B, slow jams, šanson a jazzové zpěvačky – "
        "od Marvina Gaye po Norah Jones."
    ),
    "sad": (
        "Na chvíle, kdy je smutno: slowcore, emo, dream pop a písničkáři. Hudba, která nepřebíjí, "
        "ale sedne si vedle tebe."
    ),
    "morning": (
        "Na pomalé ráno a první kávu: akustické písničky, indie folk, bossa nova a lehký jazz."
    ),
    "roadtrip": (
        "Do auta a na cesty: classic rock, americana, heartland rock a synthwave – refrény na zpívání "
        "a kilometry, které rychle ubíhají."
    ),
}
