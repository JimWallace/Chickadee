// UI text. English comes from the Unity project; French is a new translation
// (the original game downloaded its translations from a server that is no longer online).
const STRINGS = {
  en: {
    'play': 'Play', 'options': 'Options', 'cats-left': 'Cats left', 'close': 'Close', 'show-tip': 'Show cat tip', 'hide-tip': 'Hide cat tip', 'box-freed': 'Kitten box freed: {n} of {m}', 'next-cat': 'Next cat', 'pick-cat': 'Choose the real cat. Tap it, or use the arrow keys and press Space.', 'game-label': 'Quantum Cats play area', 'kb-help': 'Keyboard: press Space to aim, Up and Down to change the angle, Left and Right to change the power, then Space to launch. Escape cancels. When not aiming, Left and Right look around. Space also uses a cat’s power while it flies.', 'boxes-label': 'Kitten boxes freed', 'credits': 'Credits', 'credits-title': 'Credits', 'language': 'Français',
    'select-a-level': 'Select a Level', 'cat-levels': 'Meet the cats', 'lab-levels': 'In the lab',
    'score': 'Score', 'you-win': 'You Win!', 'try-again': 'Try Again', 'cat-bonus': 'Cat Bonus',
    'total-score': 'Total Score', 'tip': 'Tip', 'next': 'Next', 'retry': 'Retry', 'wl-menu': 'Menu',
    'reset': 'Reset', 'menu': 'Menu', 'sound': 'Sound', 'music': 'Music', 'on': 'On', 'off': 'Off',
    'level': 'Level', 'learn': 'Learn about this cat', 'close': 'Close', 'loading': 'Loading the lab…',
    'facts': 'Facts', 'rotate': 'Turn your device sideways for a better view.',
    'boxes': 'Kitten boxes freed',
    'cat-type-classy': 'Classical Cat',
    'cat-description-classy': 'Pull back on the launcher and let go. She follows Newton’s laws, so you know where she’s going.',
    'cat-type-digger': 'Quantum Tunnelling Cat',
    'cat-description-digger': 'Can pass through solid objects! He tunnels through the first thing in his path.',
    'cat-type-schro': 'Superposition Cat',
    'cat-description-schro': 'Launches as three cats at once. When they’re about to hit something, tap the one that’s real.',
    'cat-type-fuzzy': 'Uncertainty Cat',
    'cat-description-fuzzy': 'Becomes a cloud of possibilities. Tap anywhere while she’s flying to find out where she lands.',
    'tips': [
      'Pull the launcher further back to fire harder.',
      'Drag down to aim higher. Drag up to aim lower.',
      'Glass breaks easily. Metal takes a real hit.',
      'Knock heavy pieces onto the kitten boxes. Falling metal does a lot of damage.',
      'Tap two waiting cats to swap their order.',
      'Hit a liquid helium tank to freeze everything nearby. Frozen objects shatter easily.',
      'Unused cats are worth 1000 bonus points each.'
    ],
    edu: {
      classy: { title: 'Classical Physics', name: 'Classy', bio: 'A classic cat. She acts like you would expect: you know where she’s going and where she’s been. She follows the laws of Newton and Galileo.', facts: 'The third law of motion states that for every action there is an equal and opposite reaction.' },
      schro: { title: 'Superposition', name: 'Schrö', bio: 'You never know if Schrö is in the box or if he isn’t. He has the ability to be in multiple states at the same time. He could be here, there, or both!', facts: 'A quantum system in superposition can be in multiple states at the same time: “here” and “there”, or “up” and “down”, and any combination of them.' },
      digger: { title: 'Quantum Tunnelling', name: 'Digger', bio: 'Watch this cat! He will suddenly appear on the other side of a barrier, even when he didn’t have the energy to go over it or break it down.', facts: 'The wave-like behaviour of quantum particles allows them to appear on the other side of a barrier, even if the particles don’t have the energy to go over it or break it down.' },
      fuzzy: { title: 'Uncertainty', name: 'Fuzzy', bio: 'You are never certain where you’ll find this cat. There’s a fundamental limit on how much information you can know about her.', facts: 'Heisenberg’s uncertainty principle says that there is a fundamental limit on how much information one can know about the state of a quantum system.' }
    },
    thanksList: ['Mike and Ophelia Lazaridis', 'The Province of Ontario', 'The Government of Canada', 'The Quantum Arcade by UBC Geering Up Engineering Outreach'],
    bugsHead: 'Bugs?', bugsLine: 'Email iqc-outreach@uwaterloo.ca',
    creditHeads: ['Concept and Design', 'Game Developers', 'Art', 'IQC Scientific Contributors', 'IQC Project Managers', 'HTML version', 'Special Thanks']
  },
  fr: {
    'play': 'Jouer', 'options': 'Options', 'cats-left': 'Chats restants', 'close': 'Fermer', 'show-tip': 'Afficher le conseil', 'hide-tip': 'Masquer le conseil', 'box-freed': 'Boîte de chatons libérée : {n} sur {m}', 'next-cat': 'Prochain chat', 'pick-cat': 'Choisis le vrai chat. Touche-le, ou utilise les flèches puis appuie sur Espace.', 'game-label': 'Zone de jeu Quantum Cats', 'kb-help': 'Clavier : appuie sur Espace pour viser, Haut et Bas pour l’angle, Gauche et Droite pour la puissance, puis Espace pour lancer. Échap annule. Sans viser, Gauche et Droite déplacent la vue. Espace active aussi le pouvoir d’un chat en vol.', 'boxes-label': 'Boîtes de chatons libérées', 'credits': 'Crédits', 'credits-title': 'Crédits', 'language': 'English',
    'select-a-level': 'Choisis un niveau', 'cat-levels': 'Rencontre les chats', 'lab-levels': 'Au labo',
    'score': 'Pointage', 'you-win': 'Bravo!', 'try-again': 'Essaie encore', 'cat-bonus': 'Bonus chats',
    'total-score': 'Pointage total', 'tip': 'Astuce', 'next': 'Suivant', 'retry': 'Recommencer', 'wl-menu': 'Menu',
    'reset': 'Recommencer', 'menu': 'Menu', 'sound': 'Son', 'music': 'Musique', 'on': 'Oui', 'off': 'Non',
    'level': 'Niveau', 'learn': 'En savoir plus sur ce chat', 'close': 'Fermer', 'loading': 'Préparation du labo…',
    'facts': 'Le savais-tu?', 'rotate': 'Tourne ton appareil à l’horizontale pour mieux voir.',
    'boxes': 'Boîtes de chatons libérées',
    'cat-type-classy': 'Chat classique',
    'cat-description-classy': 'Tire le lanceur vers l’arrière, puis relâche. Elle suit les lois de Newton : tu sais où elle va.',
    'cat-type-digger': 'Chat à effet tunnel',
    'cat-description-digger': 'Il traverse les objets solides! Il passe à travers le premier obstacle sur son chemin.',
    'cat-type-schro': 'Chat en superposition',
    'cat-description-schro': 'Il part en trois chats à la fois. Juste avant l’impact, touche celui qui est réel.',
    'cat-type-fuzzy': 'Chat de l’incertitude',
    'cat-description-fuzzy': 'Elle devient un nuage de possibilités. Touche l’écran pendant son vol pour savoir où elle atterrit.',
    'tips': [
      'Tire le lanceur plus loin pour lancer plus fort.',
      'Glisse vers le bas pour viser plus haut, vers le haut pour viser plus bas.',
      'Le verre casse facilement. Le métal résiste mieux.',
      'Fais tomber les pièces lourdes sur les boîtes de chatons. Le métal qui tombe fait beaucoup de dégâts.',
      'Touche deux chats en attente pour changer leur ordre.',
      'Frappe un réservoir d’hélium liquide pour geler tout ce qui l’entoure. Les objets gelés éclatent facilement.',
      'Chaque chat que tu n’utilises pas rapporte 1000 points de bonus.'
    ],
    edu: {
      classy: { title: 'Physique classique', name: 'Classy', bio: 'Une chatte classique. Elle se comporte comme on s’y attend : on sait où elle va et d’où elle vient. Elle obéit aux lois de Newton et de Galilée.', facts: 'Selon la troisième loi du mouvement, à chaque action correspond une réaction égale et opposée.' },
      schro: { title: 'Superposition', name: 'Schrö', bio: 'On ne sait jamais si Schrö est dans la boîte ou non. Il peut être dans plusieurs états à la fois. Il pourrait être ici, là-bas, ou les deux!', facts: 'Un système quantique en superposition peut être dans plusieurs états en même temps : « ici » et « là-bas », ou « haut » et « bas », et toute combinaison des deux.' },
      digger: { title: 'Effet tunnel', name: 'Digger', bio: 'Regarde bien ce chat! Il apparaît soudain de l’autre côté d’une barrière, même s’il n’avait pas assez d’énergie pour passer par-dessus ou la briser.', facts: 'Le comportement ondulatoire des particules quantiques leur permet d’apparaître de l’autre côté d’une barrière, même sans avoir l’énergie pour la franchir ou la briser.' },
      fuzzy: { title: 'Incertitude', name: 'Fuzzy', bio: 'On n’est jamais certain de l’endroit où on trouvera cette chatte. Il y a une limite fondamentale à ce qu’on peut savoir sur elle.', facts: 'Le principe d’incertitude de Heisenberg dit qu’il existe une limite fondamentale à l’information qu’on peut connaître sur l’état d’un système quantique.' }
    },
    thanksList: ['Mike et Ophelia Lazaridis', 'La province de l’Ontario', 'Le gouvernement du Canada', 'The Quantum Arcade par UBC Geering Up Engineering Outreach'],
    bugsHead: 'Un bogue?', bugsLine: 'Écris à iqc-outreach@uwaterloo.ca',
    creditHeads: ['Concept et conception', 'Développement du jeu', 'Illustrations', 'Collaborateurs scientifiques de l’IQC', 'Gestion de projet à l’IQC', 'Version HTML', 'Remerciements spéciaux']
  }
};
const CREDITS = [
  ['James Wallace (Faculty, UW School of Public Health and Health Systems)', 'Victor Cheung (PhD Candidate, Systems Design Engineering)', 'Neil Randall (Director, The Games Institute)'],
  ['Mike Brown (Independent)', 'Jagger Nast (BMath, UW Applied Mathematics)'],
  ['Keith McLean (Independent)'],
  ['Juan Miguel Arrazola', 'John Donohue', 'Carolyn Earnest', 'Kent Fisher', 'Aimee Gunther', 'Sarah Kaiser', 'Martin Laforest', 'Jean-Philippe MacLean', 'Mike Mazurek', 'Thomas McConkey', 'Christopher Pugh', 'Jeff Salvail'],
  ['Tobi Day-Hamilton', 'Jodi Szimanski', 'Angela Olano'],
  ['Ported from the Unity project by Claude (Anthropic), 2026']
];