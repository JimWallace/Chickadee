// Core/AvatarHandleScientists.swift
//
// The people in the "disposition + scientist" scheme ("Curious Noether"), as
// one line each.  The selection rules are in docs/student-avatars.md §3: known
// mainly for the work, no major scandal, and dead or alive with a major
// honour.  Tools/handle-review reads this table as it is, so keep its form.
//
// A line has eight fields, separated by "|":
//
//     handle|full name|field|born|died|region|gender|note
//
// - handle: the name in the handle, one or two words, with diacritics and
//   real hyphens.  No apostrophes.  The lines are sorted by handle.
// - born, died: a year.  "~" marks an approximate year; a negative year is
//   BCE.  An empty "died" means that the person is alive: check every living
//   person again before each term.
// - region: one of `AvatarHandle.Scientist.Region`.
// - gender: F, M, or M+F for an entry that names two people.
//
// The list has two balance targets, which the review tool reports: at least
// 40% women and at most 35% from Europe.  People removed to meet them are in
// Tools/handle-review/data/removed-for-balance.psv.

extension AvatarHandle {

    /// The scientist table, one person per line.  `scientists` parses it.
    public static let scientistRecords = #"""
        Abbott|Maude Abbott|Medicine|1869|1940|North America|F|Canadian; world authority on congenital heart disease
        Agnesi|Maria Gaetana Agnesi|Mathematics|1718|1799|Europe|F|Wrote the first textbook on both differential and integral calculus
        Al-Battānī|Muhammad al-Battani|Astronomy|~858|929|West & Central Asia|M|Measured the length of the solar year
        Al-Bīrūnī|Abu Rayhan al-Biruni|Astronomy|973|~1050|West & Central Asia|M|Measured the radius of the Earth; wrote on geology and India
        Al-Farghānī|Ahmad al-Farghani|Astronomy|~800|~870|West & Central Asia|M|Wrote a summary of astronomy that Europe used for centuries
        Al-Haytham|Ibn al-Haytham|Physics|~965|~1040|West & Central Asia|M|Founded experimental optics; the Book of Optics
        Al-Jazarī|Ismail al-Jazari|Engineering|1136|1206|West & Central Asia|M|Book of ingenious mechanical devices; early robots and the crankshaft
        Al-Khwārizmī|Muhammad ibn Musa al-Khwarizmi|Mathematics|~780|~850|West & Central Asia|M|Founded algebra; the word "algorithm" comes from his name
        Al-Kindī|Abu Yusuf al-Kindi|Mathematics|~801|~873|West & Central Asia|M|Frequency analysis for breaking codes
        Al-Kāshī|Jamshid al-Kashi|Mathematics|~1380|1429|West & Central Asia|M|Calculated pi to sixteen digits
        Al-Rāzī|Abu Bakr al-Razi|Medicine|864|925|West & Central Asia|M|First to tell smallpox from measles
        Al-Zahrāwī|Abu al-Qasim al-Zahrawi|Medicine|936|1013|Europe|M|Father of modern surgery; designed surgical instruments
        Al-Ṣūfī|Abd al-Rahman al-Sufi|Astronomy|903|986|West & Central Asia|M|Book of Fixed Stars; first record of the Andromeda galaxy
        Al-Ṭūsī|Nasir al-Din al-Tusi|Astronomy|1201|1274|West & Central Asia|M|Built the Maragheh observatory; the Tusi couple
        Alele-Williams|Grace Alele-Williams|Mathematics|1932|2022|Africa|F|First Nigerian woman to earn a PhD; mathematics education
        Alice Ball|Alice Ball|Chemistry|1892|1916|North America|F|Made the first effective injectable treatment for leprosy
        Almeida|June Almeida|Biology|1930|2007|Europe|F|Virologist; first image of a coronavirus
        Alper|Tikvah Alper|Biology|1909|1995|Africa|F|South African radiobiologist; showed that prions contain no nucleic acid
        Amano|Hiroshi Amano|Engineering|1960||East Asia|M|Alive. Blue light-emitting diodes; Nobel Prize
        Ambartsumian|Viktor Ambartsumian|Astronomy|1908|1996|West & Central Asia|M|Armenian; founded theoretical astrophysics of stellar groups
        Ampère|André-Marie Ampère|Physics|1775|1836|Europe|M|Founded electrodynamics
        Anning|Mary Anning|Earth science|1799|1847|Europe|F|Fossil hunter who found the first ichthyosaur skeleton
        Antonelli|Kathleen Antonelli|Computing|1921|2006|Europe|F|Irish-born ENIAC programmer; invented the subroutine call
        Apgar|Virginia Apgar|Medicine|1909|1974|North America|F|The Apgar score for newborn babies
        Archimedes|Archimedes of Syracuse|Physics|~-287|~-212|Europe|M|Founded statics and hydrostatics; the principle of buoyancy
        Arf|Cahit Arf|Mathematics|1910|1997|West & Central Asia|M|Turkish mathematician; the Arf invariant
        Aryabhata|Aryabhata|Astronomy|476|550|South Asia|M|Explained eclipses and the rotation of the Earth
        Avila|Artur Avila|Mathematics|1979||Latin America|M|Alive. Brazilian; dynamical systems; Fields Medal
        Avogadro|Amedeo Avogadro|Chemistry|1776|1856|Europe|M|Equal volumes of gas hold equal numbers of molecules
        Ayrton|Hertha Ayrton|Physics|1854|1923|Europe|F|Studied the electric arc and ripples in sand
        Babbage|Charles Babbage|Computing|1791|1871|Europe|M|Designed the Difference and Analytical Engines
        Backus|John Backus|Computing|1924|2007|North America|M|FORTRAN; Backus–Naur form
        Banneker|Benjamin Banneker|Astronomy|1731|1806|North America|M|Self-taught astronomer; published almanacs; surveyed Washington, D.C.
        Banting|Frederick Banting|Medicine|1891|1941|North America|M|Canadian; co-found insulin
        Bari|Nina Bari|Mathematics|1901|1961|Europe|F|Trigonometric series
        Barnard|Christiaan Barnard|Medicine|1922|2001|Africa|M|South African; first human heart transplant
        Barroso|Graziela Barroso|Biology|1912|2003|Latin America|F|Brazil's leading woman botanist
        Barré-Sinoussi|Françoise Barré-Sinoussi|Biology|1947||Europe|F|Alive. Co-found HIV; Nobel Prize
        Bartik|Jean Bartik|Computing|1924|2011|North America|F|ENIAC programmer; stored-program conversion
        Bascom|Florence Bascom|Earth science|1862|1945|North America|F|First woman geologist of the US Geological Survey
        Bassi|Laura Bassi|Physics|1711|1778|Europe|F|First woman to hold a university chair in physics
        Bawendi|Moungi Bawendi|Chemistry|1961||Africa|M|Alive. Tunisian-born; quantum dots; Nobel Prize
        Bayes|Thomas Bayes|Statistics|1701|1761|Europe|M|Bayes' theorem on conditional probability
        Begay|Fred Begay|Physics|1932|2013|North America|M|Navajo nuclear physicist; laser fusion research
        Bell Burnell|Jocelyn Bell Burnell|Astronomy|1943||Europe|F|Alive. Found the first pulsars; Breakthrough Prize
        Benacerraf|Baruj Benacerraf|Medicine|1920|2011|Latin America|M|Venezuelan; genes that control the immune response
        Benerito|Ruth Benerito|Chemistry|1916|2013|North America|F|Invented wrinkle-free cotton
        Berezin|Evelyn Berezin|Computing|1925|2018|North America|F|Built the first computer word processor
        Bertozzi|Carolyn Bertozzi|Chemistry|1966||North America|F|Alive. Bioorthogonal chemistry; Nobel Prize
        Bhabha|Homi J. Bhabha|Physics|1909|1966|South Asia|M|Electron–positron scattering; founded India's nuclear research
        Bhargava|Manjul Bhargava|Mathematics|1974||South Asia|M|Alive. Number theory; Fields Medal
        Bhatnagar|Shanti Swarup Bhatnagar|Chemistry|1894|1955|South Asia|M|Magnetochemistry; founded India's national laboratories
        Bhāskara|Bhāskara II|Mathematics|1114|1185|South Asia|M|Early ideas of calculus; the Lilavati
        Birkar|Caucher Birkar|Mathematics|1978||West & Central Asia|M|Alive. Kurdish mathematician; algebraic geometry; Fields Medal
        Blackburn|Elizabeth Blackburn|Biology|1948||Oceania|F|Alive. Australian; telomeres and telomerase; Nobel Prize
        Blackwell|Elizabeth Blackwell and David Blackwell|Medicine|1821|2010|North America|F|First woman to earn an MD in the US (Elizabeth); see also the statistician David
        Blau|Marietta Blau|Physics|1894|1970|Europe|F|Photographic method for tracking particles
        Blodgett|Katharine Burr Blodgett|Chemistry|1898|1979|North America|F|Invented non-reflective glass
        Bohr|Niels Bohr|Physics|1885|1962|Europe|M|Quantum model of the atom
        Boltzmann|Ludwig Boltzmann|Physics|1844|1906|Europe|M|Founded statistical mechanics
        Boole|George Boole|Mathematics|1815|1864|Europe|M|Boolean algebra, the logic of computers
        Bose|Jagadish Chandra Bose and Satyendra Nath Bose|Physics|1858|1974|South Asia|M|Microwave optics (J. C.); Bose–Einstein statistics (S. N.)
        Bouchet|Edward Bouchet|Physics|1852|1918|North America|M|First African American to earn a PhD, in physics
        Boykin|Otis Boykin|Engineering|1920|1982|North America|M|Invented resistors used in pacemakers and guided missiles
        Boyle|Robert Boyle and Willard Boyle|Physics|1627|2011|Europe|M|Gas law (Robert); the CCD image sensor (Willard, Canadian)
        Brahe|Tycho Brahe|Astronomy|1546|1601|Europe|M|Made the most precise naked-eye observations of the planets
        Brahmagupta|Brahmagupta|Mathematics|598|668|South Asia|M|Rules for zero and negative numbers
        Brenner|Sydney Brenner|Biology|1927|2019|Africa|M|South African; messenger RNA and the genetic code
        Brockhouse|Bertram Brockhouse|Physics|1918|2003|North America|M|Canadian; neutron scattering
        Brooks|Harriet Brooks|Physics|1876|1933|North America|F|Canada's first woman nuclear physicist; found radon recoil
        Browne|Marjorie Lee Browne|Mathematics|1914|1979|North America|F|Matrix theory; early computing in mathematics education
        Bunsen|Robert Bunsen|Chemistry|1811|1899|Europe|M|Spectroscopy; the Bunsen burner
        Burbidge|Margaret Burbidge|Astronomy|1919|2020|Europe|F|How stars make the chemical elements; quasars
        Cajal|Santiago Ramón y Cajal|Biology|1852|1934|Europe|M|Founded modern neuroscience; the neuron doctrine
        Caldas|Francisco José de Caldas|Earth science|1768|1816|Latin America|M|Colombian; measured altitude from the boiling point of water
        Camarena|Guillermo González Camarena|Engineering|1917|1965|Latin America|M|Mexican; invented a colour television system
        Cannon|Annie Jump Cannon|Astronomy|1863|1941|North America|F|Made the system that classifies stars by spectrum
        Cantor|Georg Cantor|Mathematics|1845|1918|Europe|M|Set theory; sizes of infinity
        Carson|Rachel Carson|Biology|1907|1964|North America|F|Silent Spring; started the environmental movement
        Cartwright|Mary Cartwright|Mathematics|1900|1998|Europe|F|Early work in chaos theory
        Carver|George Washington Carver|Chemistry|1864|1943|North America|M|Agricultural chemist; crop rotation and soil health
        Chagas|Carlos Chagas|Medicine|1879|1934|Latin America|M|Brazilian; described Chagas disease in full
        Chakravarty|Charusita Chakravarty|Chemistry|1964|2016|South Asia|F|Indian theoretical chemist; the structure of water and liquids
        Chandrasekhar|Subrahmanyan Chandrasekhar|Astronomy|1910|1995|South Asia|M|The mass limit of white dwarf stars
        Charles Drew|Charles R. Drew|Medicine|1904|1950|North America|M|Developed large-scale blood banks
        Charpentier|Emmanuelle Charpentier|Biology|1968||Europe|F|Alive. CRISPR gene editing; Nobel Prize
        Chatterjee|Asima Chatterjee and Rajeshwari Chatterjee|Chemistry|1917|2010|South Asia|F|Plant-based drugs for epilepsy and malaria (Asima); microwave engineering (Rajeshwari)
        Chawla|Kalpana Chawla|Engineering|1962|2003|South Asia|F|Aerospace engineer and astronaut
        Chern|Shiing-Shen Chern|Mathematics|1911|2004|East Asia|M|Differential geometry; Chern classes
        Chien-Shiung Wu|Chien-Shiung Wu|Physics|1912|1997|East Asia|F|Showed that parity is not conserved in weak interactions
        Chowdhuri|Bibha Chowdhuri|Physics|1913|1991|South Asia|F|Indian particle physicist; cosmic-ray research
        Châtelet|Émilie du Châtelet|Physics|1706|1749|Europe|F|Translated and extended Newton's Principia; energy and kinetic force
        Clarke|Edith Clarke and Joan Clarke|Engineering|1883|1996|North America|F|First US woman professor of electrical engineering (Edith); Enigma codebreaker (Joan)
        Conway|John Horton Conway and Lynn Conway|Mathematics|1937|2024|Europe|M|The Game of Life (John); VLSI chip design (Lynn)
        Copernicus|Nicolaus Copernicus|Astronomy|1473|1543|Europe|M|Proposed the heliocentric model of the solar system
        Cori|Gerty Cori|Biology|1896|1957|North America|F|How the body stores and uses sugar
        Cormack|Allan Cormack|Medicine|1924|1998|Africa|M|South African; theory of the CT scan
        Coxeter|H. S. M. Coxeter|Mathematics|1907|2003|North America|M|Canadian; geometry and symmetry groups
        Crumpler|Rebecca Lee Crumpler|Medicine|1831|1895|North America|F|First African American woman to earn an MD
        Curie|Marie Skłodowska-Curie|Physics|1867|1934|Europe|F|Pioneer of radioactivity; Nobel Prizes in physics and chemistry
        Dalton|John Dalton|Chemistry|1766|1844|Europe|M|Atomic theory; studied colour blindness
        Daly|Marie Maynard Daly|Chemistry|1921|2003|North America|F|First African American woman to earn a PhD in chemistry
        Darden|Christine Darden|Engineering|1942||North America|F|Alive. Research on sonic booms at NASA; Congressional Gold Medal
        Darwin|Charles Darwin|Biology|1809|1882|Europe|M|Evolution by natural selection
        Daubechies|Ingrid Daubechies|Mathematics|1954||Europe|F|Alive. Wavelets, used in image compression; Wolf Prize
        Davy|Humphry Davy|Chemistry|1778|1829|Europe|M|Isolated sodium and potassium by electrolysis; the miner's safety lamp
        Derick|Carrie Derick|Biology|1862|1941|North America|F|Canada's first woman professor; botany and genetics at McGill
        Descartes|René Descartes|Mathematics|1596|1650|Europe|M|Coordinate geometry
        Dhawan|Satish Dhawan|Engineering|1920|2002|South Asia|M|Led India's space program; fluid dynamics
        Dijkstra|Edsger W. Dijkstra|Computing|1930|2002|Europe|M|Shortest-path algorithm; structured programming
        Diop|Cheikh Anta Diop|Physics|1923|1986|Africa|M|Senegalese scientist; founded a radiocarbon laboratory in Dakar
        Dirac|Paul Dirac|Physics|1902|1984|Europe|M|Relativistic electron equation; predicted antimatter
        Doppler|Christian Doppler|Physics|1803|1853|Europe|M|The change in frequency of a moving source
        Doudna|Jennifer Doudna|Chemistry|1964||North America|F|Alive. CRISPR gene editing; Nobel Prize
        Döbereiner|Johanna Döbereiner|Biology|1924|2000|Latin America|F|Brazilian soil biologist; bacteria that fix nitrogen for crops
        Easley|Annie Easley|Computing|1933|2011|North America|F|NASA programmer; the Centaur rocket stage
        Eastwood|Alice Eastwood|Biology|1859|1953|North America|F|Canadian-born botanist; saved the type specimens in the 1906 San Francisco fire
        Eccles|John Eccles|Biology|1903|1997|Oceania|M|Australian; how nerve cells signal at synapses
        Einstein|Albert Einstein|Physics|1879|1955|Europe|M|Relativity; the photoelectric effect
        Elion|Gertrude B. Elion|Chemistry|1918|1999|North America|F|Designed drugs for leukemia, gout and transplant rejection
        Engelbart|Douglas Engelbart|Computing|1925|2013|North America|M|The computer mouse; hypertext and the "mother of all demos"
        Eratosthenes|Eratosthenes of Cyrene|Astronomy|~-276|~-194|Africa|M|Measured the circumference of the Earth from shadows
        Erdős|Paul Erdős|Mathematics|1913|1996|Europe|M|Combinatorics; more than 1,500 papers
        Ernest Just|Ernest Everett Just|Biology|1883|1941|North America|M|Cell biology; the role of the cell surface in development
        Erxleben|Dorothea Erxleben|Medicine|1715|1762|Europe|F|First woman to earn an MD in Germany
        Estrin|Thelma Estrin|Computing|1924|2014|North America|F|Pioneer of computers in biomedical research
        Euclid|Euclid of Alexandria|Mathematics|~-325|~-265|Africa|M|The Elements, the model for mathematical proof
        Euler|Leonhard Euler|Mathematics|1707|1783|Europe|M|Graph theory; the notation e, i and f(x)
        Faraday|Michael Faraday|Physics|1791|1867|Europe|M|Electromagnetic induction; the electric motor and dynamo
        Fermat|Pierre de Fermat|Mathematics|1607|1665|Europe|M|Number theory; Fermat's last theorem
        Fermi|Enrico Fermi|Physics|1901|1954|Europe|M|First nuclear reactor; Fermi–Dirac statistics
        Fessenden|Reginald Fessenden|Engineering|1866|1932|North America|M|Canadian; first radio broadcast of voice and music
        Feynman|Richard Feynman|Physics|1918|1988|North America|M|Quantum electrodynamics; Feynman diagrams
        Fibonacci|Leonardo of Pisa|Mathematics|~1170|~1250|Europe|M|Brought Hindu–Arabic numerals to Europe
        Finlay|Carlos Finlay|Medicine|1833|1915|Latin America|M|Cuban; showed that mosquitoes carry yellow fever
        Fleming|Alexander Fleming and Williamina Fleming|Medicine|1857|1955|Europe|M+F|Found penicillin (Alexander); classified 10,000 stars and found the Horsehead Nebula (Williamina)
        Florey|Howard Florey|Medicine|1898|1968|Oceania|M|Australian; made penicillin into a drug
        Foote|Eunice Newton Foote|Earth science|1819|1888|North America|F|First showed that carbon dioxide traps heat
        Forsythe|Alexandra Illmer Forsythe|Computing|1918|1980|North America|F|Wrote early computer science textbooks
        Fourier|Joseph Fourier|Mathematics|1768|1830|Europe|M|Fourier series; heat flow
        Franklin|Rosalind Franklin|Chemistry|1920|1958|Europe|F|X-ray images that showed the structure of DNA
        Fukui|Kenichi Fukui|Chemistry|1918|1998|East Asia|M|Frontier orbital theory
        Galen|Galen of Pergamon|Medicine|129|~216|West & Central Asia|M|Anatomy and physiology for the next thirteen centuries
        Galileo|Galileo Galilei|Physics|1564|1642|Europe|M|Used the telescope for astronomy; studied motion and falling bodies
        Galois|Évariste Galois|Mathematics|1811|1832|Europe|M|Group theory and the solvability of equations
        Ganguly|Kadambini Ganguly|Medicine|1861|1923|South Asia|F|One of the first Indian women to practise Western medicine
        Gauss|Carl Friedrich Gauss|Mathematics|1777|1855|Europe|M|Number theory; the normal distribution
        Geiringer|Hilda Geiringer|Mathematics|1893|1973|Europe|F|Plasticity theory and probability
        Germain|Sophie Germain|Mathematics|1776|1831|Europe|F|Elasticity theory; work toward Fermat's last theorem
        Ghez|Andrea Ghez|Astronomy|1965||North America|F|Alive. The black hole at the centre of the Milky Way; Nobel Prize
        Gilbreth|Lillian Moller Gilbreth|Engineering|1878|1972|North America|F|Industrial engineering and ergonomics
        Gleditsch|Ellen Gleditsch|Chemistry|1879|1968|Europe|F|Norwegian radiochemist; measured the half-life of radium
        Godbole|Rohini Godbole|Physics|1952|2024|South Asia|F|Indian particle physicist; worked for more women in science
        Goeppert Mayer|Maria Goeppert Mayer|Physics|1906|1972|North America|F|Nuclear shell model
        Goldstine|Adele Goldstine|Computing|1920|1964|North America|F|Wrote the ENIAC manual; trained its programmers
        Goldwasser|Shafi Goldwasser|Computing|1958||West & Central Asia|F|Alive. Cryptography and zero-knowledge proofs; Turing Award
        Goodall|Jane Goodall|Biology|1934|2025|Europe|F|Chimpanzee behaviour; showed that animals make and use tools
        Granville|Evelyn Boyd Granville|Mathematics|1924|2023|North America|F|Orbit calculations for NASA's early space programs
        Greider|Carol Greider|Biology|1961||North America|F|Alive. Co-found telomerase; Nobel Prize
        Grierson|Cecilia Grierson|Medicine|1859|1934|Latin America|F|First woman physician in Argentina
        Gödel|Kurt Gödel|Mathematics|1906|1978|Europe|M|Incompleteness theorems
        Hamilton|William Rowan Hamilton and Margaret Hamilton|Mathematics|1805|1865|Europe|M+F|Quaternions (William Rowan); led the Apollo flight software and named software engineering (Margaret, alive)
        Hamming|Richard Hamming|Computing|1915|1998|North America|M|Error-correcting codes
        Harish-Chandra|Harish-Chandra|Mathematics|1923|1983|South Asia|M|Representation theory of Lie groups
        Haro|Guillermo Haro|Astronomy|1913|1988|Latin America|M|Mexican; Herbig–Haro objects and flare stars
        Haslett|Caroline Haslett|Engineering|1895|1957|Europe|F|Electrical engineer; founded the Electrical Association for Women
        Hata|Sahachirō Hata|Medicine|1873|1938|East Asia|M|Co-found the first drug for syphilis
        Hawking|Stephen Hawking|Physics|1942|2018|Europe|M|Black-hole radiation; cosmology
        Haynes|Euphemia Lofton Haynes|Mathematics|1890|1980|North America|F|First African American woman to earn a PhD in mathematics
        Hazen|Elizabeth Lee Hazen|Biology|1885|1975|North America|F|Co-found nystatin, the first antifungal antibiotic
        He Zehui|He Zehui|Physics|1914|2011|East Asia|F|Chinese nuclear physicist; found the four-way fission of uranium
        Hermann|Grete Hermann|Mathematics|1901|1984|Europe|F|Algorithms in algebra; foundations of quantum mechanics
        Herschel|Caroline Herschel|Astronomy|1750|1848|Europe|F|Found eight comets; first woman paid as a scientist in Britain
        Hertz|Heinrich Hertz|Physics|1857|1894|Europe|M|Proved that electromagnetic waves exist
        Herzberg|Gerhard Herzberg|Physics|1904|1999|North America|M|Canadian; molecular spectroscopy and free radicals
        Hidalgo|Matilde Hidalgo|Medicine|1889|1974|Latin America|F|First woman physician in Ecuador
        Hilbert|David Hilbert|Mathematics|1862|1943|Europe|M|Hilbert spaces; the 23 problems
        Hippocrates|Hippocrates of Kos|Medicine|~-460|~-370|Europe|M|Founded medicine as a profession separate from religion
        Hodgkin|Dorothy Crowfoot Hodgkin|Chemistry|1910|1994|Europe|F|Structures of penicillin, vitamin B12 and insulin
        Holberton|Betty Holberton|Computing|1917|2001|North America|F|ENIAC programmer; early sort-merge generator
        Honjo|Tasuku Honjo|Medicine|1942||East Asia|M|Alive. Found PD-1, the basis of cancer immunotherapy; Nobel Prize
        Hopper|Grace Hopper|Computing|1906|1992|North America|F|First compiler; COBOL
        Houssay|Bernardo Houssay|Medicine|1887|1971|Latin America|M|Argentine; role of the pituitary in sugar metabolism
        Hua Luogeng|Hua Luogeng|Mathematics|1910|1985|East Asia|M|Number theory; taught applied mathematics across China
        Hubble|Edwin Hubble|Astronomy|1889|1953|North America|M|Showed that the universe expands
        Humboldt|Alexander von Humboldt|Earth science|1769|1859|Europe|M|Founded biogeography; climate zones
        Hyde|Ida Hyde|Biology|1857|1945|North America|F|Physiologist; developed the microelectrode
        Hyman|Libbie Hyman|Biology|1888|1969|North America|F|Wrote the standard reference on invertebrate animals
        Hypatia|Hypatia of Alexandria|Astronomy|~360|415|Africa|F|Taught mathematics and astronomy in Alexandria
        Ibn Sīnā|Ibn Sina (Avicenna)|Medicine|980|1037|West & Central Asia|M|The Canon of Medicine, a standard text for 600 years
        Ikeda|Kikunae Ikeda|Chemistry|1864|1936|East Asia|M|Found umami, the fifth taste
        Imes|Elmer Imes|Physics|1883|1941|North America|M|Infrared spectra that confirmed quantum theory for molecules
        Immerwahr|Clara Immerwahr|Chemistry|1870|1915|Europe|F|First woman to earn a doctorate in chemistry in Germany
        Ionescu|Sofia Ionescu|Medicine|1920|2008|Europe|F|One of the first women neurosurgeons
        Ito|Kiyosi Itô|Mathematics|1915|2008|East Asia|M|Stochastic calculus
        Iwasawa|Kenkichi Iwasawa|Mathematics|1917|1998|East Asia|M|Iwasawa theory in number theory
        Jacquard|Joseph Marie Jacquard|Engineering|1752|1834|Europe|M|Punched-card loom, an ancestor of programming
        Janaki Ammal|E. K. Janaki Ammal|Biology|1897|1984|South Asia|F|Plant geneticist; bred sweet sugarcane
        Jang Yeong-sil|Jang Yeong-sil|Engineering|~1390|~1450|East Asia|M|Korean engineer; built water clocks and the first rain gauges
        Javan|Ali Javan|Physics|1926|2016|West & Central Asia|M|Iranian American; invented the gas laser
        Jemison|Mae Jemison|Engineering|1956||North America|F|Alive. Engineer and physician; first Black woman in space
        Jenner|Edward Jenner|Medicine|1749|1823|Europe|M|Made the first vaccine, against smallpox
        Jex-Blake|Sophia Jex-Blake|Medicine|1840|1912|Europe|F|Opened medical education to women in the UK
        Johnson|Katherine Johnson|Mathematics|1918|2020|North America|F|Calculated the trajectories for NASA's first crewed flights
        Joliot-Curie|Irène Joliot-Curie|Chemistry|1897|1956|Europe|F|Made the first artificial radioactive elements
        Joshi|Anandibai Joshi|Medicine|1865|1887|South Asia|F|One of the first Indian women to earn a medical degree
        Joule|James Prescott Joule|Physics|1818|1889|Europe|M|Showed that heat is a form of energy
        Kalam|A. P. J. Abdul Kalam|Engineering|1931|2015|South Asia|M|Aerospace engineer; India's launch vehicles
        Kang|Gagandeep Kang|Medicine|1962||South Asia|F|Alive. Indian virologist; rotavirus vaccines; Fellow of the Royal Society
        Karikó|Katalin Karikó|Biology|1955||Europe|F|Alive. Modified mRNA for vaccines; Nobel Prize
        Karlik|Berta Karlik|Physics|1904|1990|Europe|F|Found natural astatine
        Keller|Mary Kenneth Keller|Computing|1913|1985|North America|F|One of the first people to earn a PhD in computer science in the US
        Kelvin|William Thomson, Lord Kelvin|Physics|1824|1907|Europe|M|Absolute temperature scale; transatlantic telegraph
        Kepler|Johannes Kepler|Astronomy|1571|1630|Europe|M|Found the three laws of planetary motion
        Khayyam|Omar Khayyam|Mathematics|1048|1131|West & Central Asia|M|Solved cubic equations with geometry; reformed the calendar
        Khorana|Har Gobind Khorana|Biology|1922|2011|South Asia|M|Decoded the genetic code; made the first synthetic gene
        Kimmerer|Robin Wall Kimmerer|Biology|1953||North America|F|Alive. Potawatomi botanist; moss ecology and Indigenous knowledge; MacArthur Fellowship
        Kimura|Motoo Kimura|Biology|1924|1994|East Asia|M|Neutral theory of molecular evolution
        Kitasato|Kitasato Shibasaburō|Medicine|1853|1931|East Asia|M|Grew the tetanus bacillus; co-found antitoxin therapy
        Klug|Aaron Klug|Chemistry|1926|2018|Africa|M|Raised in South Africa; crystallographic electron microscopy
        Kodaira|Kunihiko Kodaira|Mathematics|1915|1997|East Asia|M|Complex manifolds; first Fields Medal from Japan
        Kolmogorov|Andrey Kolmogorov|Mathematics|1903|1987|Europe|M|Axioms of probability
        Koshiba|Masatoshi Koshiba|Physics|1926|2020|East Asia|M|Detected neutrinos from a supernova
        Kovalevskaya|Sofya Kovalevskaya|Mathematics|1850|1891|Europe|F|Partial differential equations; first woman with a full professorship in Northern Europe
        Kurien|Verghese Kurien|Engineering|1921|2012|South Asia|M|Engineer who led India's milk revolution
        Kuroda|Chika Kuroda|Chemistry|1884|1968|East Asia|F|First Japanese woman to earn a science degree; natural dyes
        Kwolek|Stephanie Kwolek|Chemistry|1923|2014|North America|F|Invented Kevlar
        Ladyzhenskaya|Olga Ladyzhenskaya|Mathematics|1922|2004|Europe|F|Partial differential equations; fluid dynamics
        Lamarr|Hedy Lamarr|Engineering|1914|2000|Europe|F|Co-invented frequency hopping for secure radio
        Lambek|Joachim Lambek|Mathematics|1922|2014|North America|M|Canadian; category theory and the Lambek calculus
        Lambo|Thomas Adeoye Lambo|Medicine|1923|2004|Africa|M|Nigerian psychiatrist; community-based mental health care
        Laplace|Pierre-Simon Laplace|Mathematics|1749|1827|Europe|M|Celestial mechanics; probability theory
        Latimer|Lewis Howard Latimer|Engineering|1848|1928|North America|M|Improved the carbon filament of the light bulb
        Lattes|César Lattes|Physics|1924|2005|Latin America|M|Co-found the pion
        Lavoisier|Antoine and Marie-Anne Lavoisier|Chemistry|1743|1836|Europe|M|Named oxygen and hydrogen; conservation of mass
        Leavitt|Henrietta Swan Leavitt|Astronomy|1868|1921|North America|F|Found the period–luminosity relation that measures cosmic distance
        Lederberg|Esther Lederberg|Biology|1922|2006|North America|F|Found the lambda phage; replica plating
        Leeuwenhoek|Antonie van Leeuwenhoek|Biology|1632|1723|Europe|M|Saw bacteria and other microbes for the first time
        Lehmann|Inge Lehmann|Earth science|1888|1993|Europe|F|Found the solid inner core of the Earth
        Leibniz|Gottfried Wilhelm Leibniz|Mathematics|1646|1716|Europe|M|Calculus notation; binary numbers
        Leloir|Luis Federico Leloir|Chemistry|1906|1987|Latin America|M|Argentine; how cells make sugars
        Lemaître|Georges Lemaître|Astronomy|1894|1966|Europe|M|Proposed the expanding universe and the primeval atom
        Levi-Montalcini|Rita Levi-Montalcini|Biology|1909|2012|Europe|F|Found nerve growth factor
        Lin Qiaozhi|Lin Qiaozhi|Medicine|1901|1983|East Asia|F|Founded modern obstetrics and gynaecology in China
        Lister|Joseph Lister|Medicine|1827|1912|Europe|M|Antiseptic surgery
        Lonsdale|Kathleen Lonsdale|Chemistry|1903|1971|Europe|F|Showed that the benzene ring is flat
        Lovelace|Ada Lovelace|Computing|1815|1852|Europe|F|Wrote the first published computer program
        Luisi|Paulina Luisi|Medicine|1875|1950|Latin America|F|First woman physician in Uruguay
        Lutz|Adolfo Lutz and Bertha Lutz|Medicine|1855|1976|Latin America|M+F|Tropical medicine (Adolfo); zoology and women's rights (Bertha)
        Lyell|Charles Lyell|Earth science|1797|1875|Europe|M|Principles of Geology
        Maathai|Wangari Maathai|Biology|1940|2011|Africa|F|Founded the Green Belt Movement; Nobel Peace Prize
        MacGill|Elsie MacGill|Engineering|1905|1980|North America|F|Canadian; first woman aircraft designer
        Mahalanobis|Prasanta Chandra Mahalanobis|Statistics|1893|1972|South Asia|M|Mahalanobis distance; founded the Indian Statistical Institute
        Mandelbrot|Benoit Mandelbrot|Mathematics|1924|2010|Europe|M|Fractal geometry
        Mani|Anna Mani|Earth science|1918|2001|South Asia|F|Indian meteorologist; instruments for solar radiation and ozone
        Marić|Mileva Marić|Physics|1875|1948|Europe|F|Serbian physicist and mathematician; one of the first women to study physics in Zurich
        Markov|Andrey Markov|Mathematics|1856|1922|Europe|M|Markov chains
        Mary Jackson|Mary Jackson|Engineering|1921|2005|North America|F|NASA's first Black woman engineer; aerodynamics
        Maskawa|Toshihide Maskawa|Physics|1940|2021|East Asia|M|Predicted a third family of quarks
        Matzeliger|Jan Ernst Matzeliger|Engineering|1852|1889|Latin America|M|Born in Suriname; invented the shoe-lasting machine
        Maunder|Annie Maunder|Astronomy|1868|1947|Europe|F|Solar astronomer; photographed the solar corona and sunspot cycles
        Mavalvala|Nergis Mavalvala|Physics|1968||South Asia|F|Alive. Pakistani American; detected gravitational waves at LIGO; MacArthur Fellowship
        Maxwell|James Clerk Maxwell|Physics|1831|1879|Europe|M|Equations that unite electricity, magnetism and light
        McClintock|Barbara McClintock|Biology|1902|1992|North America|F|Found genes that move: transposons
        McCoy|Elijah McCoy|Engineering|1844|1929|North America|M|Canadian-born; automatic lubricators for steam engines
        McLaren|Anne McLaren|Biology|1927|2007|Europe|F|Developmental biology; work that led to IVF
        Meitner|Lise Meitner|Physics|1878|1968|Europe|F|Explained nuclear fission
        Meltzer|Marlyn Meltzer|Computing|1922|2008|North America|F|ENIAC programmer
        Mendel|Gregor Mendel|Biology|1822|1884|Europe|M|Founded genetics with experiments on peas
        Mendeleev|Dmitri Mendeleev|Chemistry|1834|1907|Europe|M|The periodic table of the elements
        Merian|Maria Sibylla Merian|Biology|1647|1717|Europe|F|Observed and drew the life cycles of insects
        Mexía|Ynés Mexía|Biology|1870|1938|Latin America|F|Mexican American botanist; collected 145,000 plant specimens
        Milanković|Milutin Milanković|Earth science|1879|1958|Europe|M|Orbital cycles that drive the ice ages
        Milstein|César Milstein|Biology|1927|2002|Latin America|M|Argentine; monoclonal antibodies
        Mirzakhani|Maryam Mirzakhani|Mathematics|1977|2017|West & Central Asia|F|Geometry of Riemann surfaces; first woman to win the Fields Medal
        Mitchell|Maria Mitchell|Astronomy|1818|1889|North America|F|First professional woman astronomer in the United States
        Mohorovičić|Andrija Mohorovičić|Earth science|1857|1936|Europe|M|Found the boundary between the crust and the mantle
        Molina|Mario Molina|Chemistry|1943|2020|Latin America|M|Mexican; showed that CFCs destroy the ozone layer
        Morawetz|Cathleen Synge Morawetz|Mathematics|1923|2017|North America|F|Canadian-born; shock waves and transonic flow
        Moser|May-Britt Moser and Edvard Moser|Biology|1962||Europe|M+F|Alive. Grid cells, the brain's positioning system; Nobel Prize
        Mosharafa|Ali Moustafa Mosharafa|Physics|1898|1950|Africa|M|Egyptian physicist; quantum theory and relativity
        Moufang|Ruth Moufang|Mathematics|1905|1977|Europe|F|Moufang planes and loops
        Moumouni|Abdou Moumouni Dioffo|Physics|1929|1991|Africa|M|Nigerien physicist; pioneer of solar energy in Africa
        Moussa|Sameera Moussa|Physics|1917|1952|Africa|F|Egyptian nuclear physicist; worked for the peaceful use of nuclear medicine
        Mutis|José Celestino Mutis|Biology|1732|1808|Latin America|M|Led the botanical survey of New Granada
        Nagaoka|Hantaro Nagaoka|Physics|1865|1950|East Asia|M|Proposed the Saturnian model of the atom
        Nambu|Yoichiro Nambu|Physics|1921|2015|East Asia|M|Spontaneous symmetry breaking
        Nash|John Forbes Nash Jr.|Mathematics|1928|2015|North America|M|Game theory; the Nash equilibrium
        Negishi|Ei-ichi Negishi|Chemistry|1935|2021|East Asia|M|Negishi coupling
        Neumann|John von Neumann and Klára Dán von Neumann|Mathematics|1903|1963|Europe|M+F|Game theory (John); wrote the first modern-style program for ENIAC (Klára)
        Newton|Isaac Newton and Margaret Newton|Physics|1643|1971|Europe|M+F|Laws of motion and gravitation (Isaac); wheat rust research in Canada (Margaret)
        Nightingale|Florence Nightingale|Medicine|1820|1910|Europe|F|Founded modern nursing; pioneer of statistical graphics
        Nishina|Yoshio Nishina|Physics|1890|1951|East Asia|M|Founded modern physics research in Japan
        Noddack|Ida Noddack|Physics|1896|1978|Europe|F|Co-found rhenium; first proposed nuclear fission
        Noether|Emmy Noether|Mathematics|1882|1935|Europe|F|Abstract algebra; symmetry and conservation laws
        Nyokong|Tebello Nyokong|Chemistry|1951||Africa|F|Alive. South African chemist; light-activated cancer drugs; L'Oréal-UNESCO Award
        Nüsslein-Volhard|Christiane Nüsslein-Volhard|Biology|1942||Europe|F|Alive. Genes that control early development; Nobel Prize
        Ochoa|Severo Ochoa|Biology|1905|1993|Europe|M|Synthesis of RNA
        Odhiambo|Thomas Risley Odhiambo|Biology|1931|2003|Africa|M|Kenyan entomologist; founded the ICIPE research centre
        Ogino|Ogino Ginko|Medicine|1851|1913|East Asia|F|Japan's first licensed woman physician in Western medicine
        Ohm|Georg Ohm|Physics|1789|1854|Europe|M|Law relating voltage, current and resistance
        Ohno|Susumu Ohno|Biology|1928|2000|East Asia|M|Evolution by gene duplication
        Ohsumi|Yoshinori Ohsumi|Biology|1945||East Asia|M|Alive. How cells recycle their parts (autophagy); Nobel Prize
        Oka|Kiyoshi Oka|Mathematics|1901|1978|East Asia|M|Functions of several complex variables
        Okazaki|Reiji Okazaki|Biology|1930|1975|East Asia|M|Found the Okazaki fragments of DNA replication
        Okeke|Francisca Nneka Okeke|Physics|1956||Africa|F|Alive. Nigerian physicist; the ionosphere; L'Oréal-UNESCO Award
        Oleinik|Olga Oleinik|Mathematics|1925|2001|Europe|F|Partial differential equations
        Oliphant|Mark Oliphant|Physics|1901|2000|Oceania|M|Australian; nuclear fusion of hydrogen isotopes
        Pascal|Blaise Pascal|Mathematics|1623|1662|Europe|M|Probability; Pascal's triangle; a mechanical calculator
        Pasteur|Louis Pasteur|Biology|1822|1895|Europe|M|Germ theory; pasteurization; rabies vaccine
        Patapoutian|Ardem Patapoutian|Biology|1967||West & Central Asia|M|Alive. Lebanese-born; sensors for touch and temperature; Nobel Prize
        Patricia Bath|Patricia Bath|Medicine|1942|2019|North America|F|Invented a laser method to remove cataracts
        Pauli|Wolfgang Pauli|Physics|1900|1958|Europe|M|Exclusion principle; predicted the neutrino
        Pavlov|Ivan Pavlov|Biology|1849|1936|Europe|M|Classical conditioning; physiology of digestion
        Payne-Gaposchkin|Cecilia Payne-Gaposchkin|Astronomy|1900|1979|North America|F|Showed that stars are made mostly of hydrogen and helium
        Payne-Scott|Ruby Payne-Scott|Astronomy|1912|1981|Oceania|F|Australian pioneer of radio astronomy and solar radio bursts
        Penfield|Wilder Penfield|Medicine|1891|1976|North America|M|Canadian; mapped the brain during surgery
        Pennington|Mary Engle Pennington|Chemistry|1872|1952|North America|F|Food safety and refrigeration
        Percy Julian|Percy Lavon Julian|Chemistry|1899|1975|North America|M|Made medicines from plant chemicals, including cortisone
        Perey|Marguerite Perey|Chemistry|1909|1975|Europe|F|Found francium
        Piailug|Mau Piailug|Earth science|1932|2010|Oceania|M|Micronesian master navigator; revived traditional wayfinding
        Picotte|Susan La Flesche Picotte|Medicine|1865|1915|North America|F|Omaha physician; first Native American woman to earn an MD
        Planck|Max Planck|Physics|1858|1947|Europe|M|Founded quantum theory
        Plaskett|John Stanley Plaskett|Astronomy|1865|1941|North America|M|Canadian; measured the rotation of the Milky Way
        Poincaré|Henri Poincaré|Mathematics|1854|1912|Europe|M|Topology; chaos in the three-body problem
        Ponnamperuma|Cyril Ponnamperuma|Chemistry|1923|1994|South Asia|M|Sri Lankan; chemistry of the origin of life
        Ptolemy|Claudius Ptolemy|Astronomy|~100|~170|Africa|M|Wrote the Almagest, the standard astronomy text for 1,400 years
        Pythagoras|Pythagoras of Samos|Mathematics|~-570|~-495|Europe|M|The theorem on right triangles; numbers and music
        Pōmare|Māui Pōmare|Medicine|1875|1930|Oceania|M|First Māori medical doctor; public health for Māori communities
        Quarterman|Lloyd Quarterman|Chemistry|1918|1982|North America|M|Chemist on the Manhattan Project; fluorine chemistry
        Qudrat-i-Khuda|Muhammad Qudrat-i-Khuda|Chemistry|1900|1977|South Asia|M|Bangladeshi chemist; founded research laboratories in Dhaka
        Ramachandran|G. N. Ramachandran|Biology|1922|2001|South Asia|M|The Ramachandran plot of protein structure
        Ramakrishnan|Venki Ramakrishnan|Biology|1952||South Asia|M|Alive. Structure of the ribosome; Nobel Prize
        Raman|C. V. Raman|Physics|1888|1970|South Asia|M|Found the Raman scattering of light
        Ramanujan|Srinivasa Ramanujan|Mathematics|1887|1920|South Asia|M|Self-taught; thousands of results on series and partitions
        Ranadive|Kamal Ranadive|Medicine|1917|2001|South Asia|F|Indian cancer researcher; founded the Indian Women Scientists' Association
        Ranganathan|Darshan Ranganathan|Chemistry|1941|2001|South Asia|F|Indian organic chemist; designed molecules that mimic proteins
        Rao|C. R. Rao|Statistics|1920|2023|South Asia|M|Cramér–Rao bound; Rao–Blackwell theorem
        Riemann|Bernhard Riemann|Mathematics|1826|1866|Europe|M|Riemann geometry; the Riemann hypothesis
        Rillieux|Norbert Rillieux|Engineering|1806|1894|North America|M|Invented the multiple-effect evaporator for refining sugar
        Ritchie|Dennis Ritchie|Computing|1941|2011|North America|M|The C language; co-created Unix
        Roebling|Emily Warren Roebling|Engineering|1843|1903|North America|F|Led the completion of the Brooklyn Bridge
        Ross|Mary Golda Ross|Engineering|1908|2008|North America|F|Cherokee; first Native American woman engineer; spacecraft design
        Rubin|Vera Rubin|Astronomy|1928|2016|North America|F|Evidence for dark matter from galaxy rotation
        Rudin|Mary Ellen Rudin|Mathematics|1924|2013|North America|F|Set-theoretic topology
        Ruth Arnon|Ruth Arnon|Biology|1933||West & Central Asia|F|Alive. Co-developed a drug for multiple sclerosis; Israel Prize
        Rutherford|Ernest Rutherford|Physics|1871|1937|Oceania|M|New Zealander; found the atomic nucleus
        Röntgen|Wilhelm Röntgen|Physics|1845|1923|Europe|M|Found X-rays
        Sagan|Carl Sagan|Astronomy|1934|1996|North America|M|Planetary science; taught astronomy to the public
        Sager|Ruth Sager|Biology|1918|1997|North America|F|Found genes outside the cell nucleus
        Saha|Meghnad Saha|Astronomy|1893|1956|South Asia|M|Ionization equation used to read the spectra of stars
        Sahni|Birbal Sahni|Earth science|1891|1949|South Asia|M|Founded palaeobotany in India
        Sakata|Shoichi Sakata|Physics|1911|1970|East Asia|M|The Sakata model of hadrons
        Sakharov|Andrei Sakharov|Physics|1921|1989|Europe|M|Physicist and human-rights campaigner; Nobel Peace Prize
        Salam|Abdus Salam|Physics|1926|1996|South Asia|M|Electroweak unification; Pakistan's first Nobel laureate in science
        Sammet|Jean E. Sammet|Computing|1928|2017|North America|F|COBOL; history of programming languages
        Sancar|Aziz Sancar|Chemistry|1946||West & Central Asia|M|Alive. How cells repair DNA; Nobel Prize
        Santos-Dumont|Alberto Santos-Dumont|Engineering|1873|1932|Latin America|M|Brazilian pioneer of airships and aircraft
        Sarabhai|Vikram Sarabhai|Physics|1919|1971|South Asia|M|Founded India's space program
        Saruhashi|Katsuko Saruhashi|Earth science|1920|2007|East Asia|F|Japanese geochemist; measured carbon dioxide and fallout in seawater
        Saylan|Türkan Saylan|Medicine|1935|2009|West & Central Asia|F|Turkish physician; fought leprosy
        Schenberg|Mário Schenberg|Physics|1914|1990|Latin America|M|Brazilian; the Urca process in supernovae
        Schiemann|Elisabeth Schiemann|Biology|1881|1972|Europe|F|History of crop plants; plant genetics
        Schrödinger|Erwin Schrödinger|Physics|1887|1961|Europe|M|Wave equation of quantum mechanics
        Seacole|Mary Seacole|Medicine|1805|1881|Latin America|F|Jamaican nurse; treated soldiers in the Crimean War
        Seki|Seki Takakazu|Mathematics|1642|1708|East Asia|M|Found determinants before Leibniz
        Semmelweis|Ignaz Semmelweis|Medicine|1818|1865|Europe|M|Showed that handwashing prevents infection
        Shannon|Claude Shannon|Computing|1916|2001|North America|M|Founded information theory
        Shen Kuo|Shen Kuo|Earth science|1031|1095|East Asia|M|Described the magnetic compass and how landforms erode
        Shiga|Kiyoshi Shiga|Biology|1871|1957|East Asia|M|Found the dysentery bacillus, Shigella
        Shilling|Beatrice Shilling|Engineering|1909|1990|Europe|F|Fixed a fuel-flow fault in fighter aircraft engines
        Shima|Hideo Shima|Engineering|1901|1998|East Asia|M|Chief engineer of the Shinkansen bullet train
        Shimomura|Osamu Shimomura|Biology|1928|2018|East Asia|M|Found green fluorescent protein
        Silveira|Nise da Silveira|Medicine|1905|1999|Latin America|F|Brazilian psychiatrist; used art therapy instead of harsh treatments
        Sinha|Purnima Sinha|Physics|1927|2015|South Asia|F|Indian physicist; X-ray crystallography of clays and biological molecules
        Sohonie|Kamala Sohonie|Chemistry|1911|1998|South Asia|F|Indian biochemist; first Indian woman to earn a PhD in science
        Somerville|Mary Somerville|Astronomy|1780|1872|Europe|F|Explained celestial mechanics; predicted a planet beyond Uranus
        Spence|Frances Spence|Computing|1922|2012|North America|F|ENIAC programmer
        Spärck Jones|Karen Spärck Jones|Computing|1935|2007|Europe|F|Inverse document frequency, the basis of search engines
        Stevens|Nettie Stevens|Biology|1861|1912|North America|F|Found that chromosomes determine sex
        Stowe|Emily Stowe|Medicine|1831|1903|North America|F|One of Canada's first women physicians
        Strickland|Donna Strickland|Physics|1959||North America|F|Alive. Canadian; chirped pulse amplification of lasers; Nobel Prize; University of Waterloo
        Subbarow|Yellapragada Subbarow|Medicine|1895|1948|South Asia|M|Made methotrexate; found the role of ATP in muscle
        Sudarshan|E. C. George Sudarshan|Physics|1931|2018|South Asia|M|Quantum optics; the V-A theory of weak interactions
        Sushruta|Sushruta|Medicine|~-600|~-500|South Asia|M|Early text on surgery, including reconstructive surgery
        Swaminathan|M. S. Swaminathan|Biology|1925|2023|South Asia|M|Plant geneticist; led India's green revolution
        Takagi|Teiji Takagi|Mathematics|1875|1960|East Asia|M|Class field theory
        Takamine|Jōkichi Takamine|Chemistry|1854|1922|East Asia|M|Isolated adrenaline
        Tan Yunxian|Tan Yunxian|Medicine|1461|1556|East Asia|F|Chinese physician; wrote a book of her own case records
        Taussig|Helen Taussig|Medicine|1898|1986|North America|F|Founded paediatric cardiology
        Taussky-Todd|Olga Taussky-Todd|Mathematics|1906|1995|Europe|F|Matrix theory and number theory
        Teitelbaum|Ruth Teitelbaum|Computing|1924|1986|North America|F|ENIAC programmer
        Tesla|Nikola Tesla|Engineering|1856|1943|Europe|M|Alternating-current motors and power systems
        Tharp|Marie Tharp|Earth science|1920|2006|North America|F|First map of the ocean floor; the mid-Atlantic rift
        Theiler|Max Theiler|Medicine|1899|1972|Africa|M|South African; vaccine for yellow fever
        Tinsley|Beatrice Tinsley|Astronomy|1941|1981|Oceania|F|New Zealander; showed how galaxies change as their stars age
        Tomonaga|Sin-Itiro Tomonaga|Physics|1906|1979|East Asia|M|Quantum electrodynamics
        Tu Youyou|Tu Youyou|Medicine|1930||East Asia|F|Alive. Found artemisinin for malaria; Nobel Prize
        Tukey|John Tukey|Statistics|1915|2000|North America|M|Exploratory data analysis; the fast Fourier transform; named the bit
        Tupaia|Tupaia|Earth science|~1725|1770|Oceania|M|Tahitian navigator; mapped the Pacific islands for James Cook
        Turing|Alan Turing|Computing|1912|1954|Europe|M|Theory of computation; broke Enigma
        Tutte|W. T. Tutte|Mathematics|1917|2002|North America|M|Broke the Lorenz cipher; graph theory at the University of Waterloo
        Tyndall|John Tyndall|Earth science|1820|1893|Europe|M|Measured how gases absorb heat; the greenhouse effect
        Uchida|Irene Uchida|Biology|1917|2013|North America|F|Japanese Canadian geneticist; chromosome studies of Down syndrome
        Uhlenbeck|Karen Uhlenbeck|Mathematics|1942||North America|F|Alive. Geometric analysis; Abel Prize
        Ulugh Beg|Ulugh Beg|Astronomy|1394|1449|West & Central Asia|M|Built the Samarkand observatory; a star catalogue of 1,018 stars
        Vaughan|Dorothy Vaughan|Computing|1910|2008|North America|F|Led NASA's West Area Computing unit; taught FORTRAN
        Venkatesh|Akshay Venkatesh|Mathematics|1981||South Asia|M|Alive. Number theory; Fields Medal
        Venn|John Venn|Mathematics|1834|1923|Europe|M|Venn diagrams
        Vesalius|Andreas Vesalius|Medicine|1514|1564|Europe|M|Founded modern human anatomy
        Viazovska|Maryna Viazovska|Mathematics|1984||Europe|F|Alive. Ukrainian; sphere packing in 8 and 24 dimensions; Fields Medal
        Visvesvaraya|M. Visvesvaraya|Engineering|1861|1962|South Asia|M|Dams, flood control and irrigation in India
        Vogt|Marthe Vogt|Biology|1903|2003|Europe|F|Role of noradrenaline as a neurotransmitter
        Volta|Alessandro Volta|Physics|1745|1827|Europe|M|Made the first electric battery, the voltaic pile
        Wang Zhenyi|Wang Zhenyi|Astronomy|1768|1797|East Asia|F|Explained lunar eclipses with a model; wrote on mathematics
        Watt|James Watt|Engineering|1736|1819|Europe|M|Improved the steam engine
        Wegener|Alfred Wegener|Earth science|1880|1930|Europe|M|Continental drift
        Wirth|Niklaus Wirth|Computing|1934|2024|Europe|M|Pascal and Modula-2
        Wong-Staal|Flossie Wong-Staal|Biology|1946|2020|East Asia|F|Chinese American virologist; first to clone HIV
        Worsley|Beatrice Worsley|Computing|1921|1972|North America|F|Canadian; wrote early compilers in Toronto
        Yaghi|Omar Yaghi|Chemistry|1965||West & Central Asia|M|Alive. Jordanian American; metal-organic frameworks; Wolf Prize
        Yagi|Hidetsugu Yagi|Engineering|1886|1976|East Asia|M|The Yagi–Uda antenna
        Yalow|Rosalyn Yalow|Medicine|1921|2011|North America|F|Radioimmunoassay
        Yamanaka|Shinya Yamanaka|Medicine|1962||East Asia|M|Alive. Reprogrammed adult cells into stem cells; Nobel Prize
        Yasui|Kono Yasui|Biology|1880|1971|East Asia|F|First Japanese woman to earn a doctorate; plant cytology
        Yau|Shing-Tung Yau|Mathematics|1949||East Asia|M|Alive. Calabi–Yau manifolds; Fields Medal
        Yermolyeva|Zinaida Yermolyeva|Medicine|1898|1974|Europe|F|Made the first Soviet penicillin
        Yoshino|Akira Yoshino|Chemistry|1948||East Asia|M|Alive. Made the first practical lithium-ion battery; Nobel Prize
        Yuasa|Toshiko Yuasa|Physics|1909|1980|East Asia|F|Japan's first woman physicist; nuclear and beta-ray spectroscopy
        Yukawa|Hideki Yukawa|Physics|1907|1981|East Asia|M|Predicted the meson; Japan's first Nobel laureate
        Zadeh|Lotfi Zadeh|Computing|1921|2017|West & Central Asia|M|Fuzzy logic and fuzzy sets
        Zewail|Ahmed Zewail|Chemistry|1946|2016|Africa|M|Femtochemistry; filmed chemical reactions
        Zhang Heng|Zhang Heng|Astronomy|78|139|East Asia|M|Built the first seismoscope and a water-powered armillary sphere
        Zoghbi|Huda Zoghbi|Medicine|1954||West & Central Asia|F|Alive. Lebanese American; the gene for Rett syndrome; Breakthrough Prize
        Zu Chongzhi|Zu Chongzhi|Mathematics|429|500|East Asia|M|Calculated pi to seven digits
        Ōmura|Satoshi Ōmura|Biology|1935||East Asia|M|Alive. Found avermectin, against river blindness; Nobel Prize
        """#
}
