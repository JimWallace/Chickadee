// Core/AvatarHandle+Scientists.swift
//
// The people the first handle scheme can name. One entry per person, sorted by
// `name`. The selection rules and the balance targets are in
// docs/student-avatars.md §3; Tools/handle-review checks every entry. Run it
// after any edit here:
//
//     node Tools/handle-review/review.mjs > /tmp/handles.html

extension AvatarHandle {

    /// Known mainly for the work, with no major scandal; no longer alive, or
    /// alive with a major honour. At least 40% women and at most 35% from
    /// Europe across the whole list.
    public static let scientists: [HandleScientist] = [
        .init(
            "Abbott", fullName: "Maude Abbott", field: "Medicine", years: "1869–1940",
            region: .northAmerica, gender: .woman,
            note: "Canadian; world authority on congenital heart disease"),
        .init(
            "Agnesi", fullName: "Maria Gaetana Agnesi", field: "Mathematics", years: "1718–1799",
            region: .europe, gender: .woman,
            note: "Wrote the first textbook on both differential and integral calculus"),
        .init(
            "Al-Battānī", fullName: "Muhammad al-Battani", field: "Astronomy", years: "c. 858–929",
            region: .westAndCentralAsia, gender: .man,
            note: "Measured the length of the solar year"),
        .init(
            "Al-Bīrūnī", fullName: "Abu Rayhan al-Biruni", field: "Astronomy", years: "973–c. 1050",
            region: .westAndCentralAsia, gender: .man,
            note: "Measured the radius of the Earth; wrote on geology and India"),
        .init(
            "Al-Farghānī", fullName: "Ahmad al-Farghani", field: "Astronomy", years: "c. 800–c. 870",
            region: .westAndCentralAsia, gender: .man,
            note: "Wrote a summary of astronomy that Europe used for centuries"),
        .init(
            "Al-Haytham", fullName: "Ibn al-Haytham", field: "Physics", years: "c. 965–c. 1040",
            region: .westAndCentralAsia, gender: .man,
            note: "Founded experimental optics; the Book of Optics"),
        .init(
            "Al-Jazarī", fullName: "Ismail al-Jazari", field: "Engineering", years: "1136–1206",
            region: .westAndCentralAsia, gender: .man,
            note: "Book of ingenious mechanical devices; early robots and the crankshaft"),
        .init(
            "Al-Khwārizmī", fullName: "Muhammad ibn Musa al-Khwarizmi", field: "Mathematics", years: "c. 780–c. 850",
            region: .westAndCentralAsia, gender: .man,
            note: "Founded algebra; the word \"algorithm\" comes from his name"),
        .init(
            "Al-Kindī", fullName: "Abu Yusuf al-Kindi", field: "Mathematics", years: "c. 801–c. 873",
            region: .westAndCentralAsia, gender: .man,
            note: "Frequency analysis for breaking codes"),
        .init(
            "Al-Kāshī", fullName: "Jamshid al-Kashi", field: "Mathematics", years: "c. 1380–1429",
            region: .westAndCentralAsia, gender: .man,
            note: "Calculated pi to sixteen digits"),
        .init(
            "Al-Rāzī", fullName: "Abu Bakr al-Razi", field: "Medicine", years: "864–925",
            region: .westAndCentralAsia, gender: .man,
            note: "First to tell smallpox from measles"),
        .init(
            "Al-Zahrāwī", fullName: "Abu al-Qasim al-Zahrawi", field: "Medicine", years: "936–1013",
            region: .europe, gender: .man,
            note: "Father of modern surgery; designed surgical instruments"),
        .init(
            "Al-Ṣūfī", fullName: "Abd al-Rahman al-Sufi", field: "Astronomy", years: "903–986",
            region: .westAndCentralAsia, gender: .man,
            note: "Book of Fixed Stars; first record of the Andromeda galaxy"),
        .init(
            "Al-Ṭūsī", fullName: "Nasir al-Din al-Tusi", field: "Astronomy", years: "1201–1274",
            region: .westAndCentralAsia, gender: .man,
            note: "Built the Maragheh observatory; the Tusi couple"),
        .init(
            "Alele-Williams", fullName: "Grace Alele-Williams", field: "Mathematics", years: "1932–2022",
            region: .africa, gender: .woman,
            note: "First Nigerian woman to earn a PhD; mathematics education"),
        .init(
            "Alice Ball", fullName: "Alice Ball", field: "Chemistry", years: "1892–1916",
            region: .northAmerica, gender: .woman,
            note: "Made the first effective injectable treatment for leprosy"),
        .init(
            "Almeida", fullName: "June Almeida", field: "Biology", years: "1930–2007",
            region: .europe, gender: .woman,
            note: "Virologist; first image of a coronavirus"),
        .init(
            "Alper", fullName: "Tikvah Alper", field: "Biology", years: "1909–1995",
            region: .africa, gender: .woman,
            note: "South African radiobiologist; showed that prions contain no nucleic acid"),
        .init(
            "Amano", fullName: "Hiroshi Amano", field: "Engineering", years: "born 1960", isLiving: true,
            region: .eastAsia, gender: .man,
            note: "Blue light-emitting diodes; Nobel Prize"),
        .init(
            "Ambartsumian", fullName: "Viktor Ambartsumian", field: "Astronomy", years: "1908–1996",
            region: .westAndCentralAsia, gender: .man,
            note: "Armenian; founded theoretical astrophysics of stellar groups"),
        .init(
            "Ampère", fullName: "André-Marie Ampère", field: "Physics", years: "1775–1836",
            region: .europe, gender: .man,
            note: "Founded electrodynamics"),
        .init(
            "Anning", fullName: "Mary Anning", field: "Earth science", years: "1799–1847",
            region: .europe, gender: .woman,
            note: "Fossil hunter who found the first ichthyosaur skeleton"),
        .init(
            "Antonelli", fullName: "Kathleen Antonelli", field: "Computing", years: "1921–2006",
            region: .europe, gender: .woman,
            note: "Irish-born ENIAC programmer; invented the subroutine call"),
        .init(
            "Apgar", fullName: "Virginia Apgar", field: "Medicine", years: "1909–1974",
            region: .northAmerica, gender: .woman,
            note: "The Apgar score for newborn babies"),
        .init(
            "Archimedes", fullName: "Archimedes of Syracuse", field: "Physics", years: "c. 287–c. 212 BCE",
            region: .europe, gender: .man,
            note: "Founded statics and hydrostatics; the principle of buoyancy"),
        .init(
            "Arf", fullName: "Cahit Arf", field: "Mathematics", years: "1910–1997",
            region: .westAndCentralAsia, gender: .man,
            note: "Turkish mathematician; the Arf invariant"),
        .init(
            "Aryabhata", fullName: "Aryabhata", field: "Astronomy", years: "476–550",
            region: .southAsia, gender: .man,
            note: "Explained eclipses and the rotation of the Earth"),
        .init(
            "Avila", fullName: "Artur Avila", field: "Mathematics", years: "born 1979", isLiving: true,
            region: .latinAmerica, gender: .man,
            note: "Brazilian; dynamical systems; Fields Medal"),
        .init(
            "Avogadro", fullName: "Amedeo Avogadro", field: "Chemistry", years: "1776–1856",
            region: .europe, gender: .man,
            note: "Equal volumes of gas hold equal numbers of molecules"),
        .init(
            "Ayrton", fullName: "Hertha Ayrton", field: "Physics", years: "1854–1923",
            region: .europe, gender: .woman,
            note: "Studied the electric arc and ripples in sand"),
        .init(
            "Babbage", fullName: "Charles Babbage", field: "Computing", years: "1791–1871",
            region: .europe, gender: .man,
            note: "Designed the Difference and Analytical Engines"),
        .init(
            "Backus", fullName: "John Backus", field: "Computing", years: "1924–2007",
            region: .northAmerica, gender: .man,
            note: "FORTRAN; Backus–Naur form"),
        .init(
            "Banneker", fullName: "Benjamin Banneker", field: "Astronomy", years: "1731–1806",
            region: .northAmerica, gender: .man,
            note: "Self-taught astronomer; published almanacs; surveyed Washington, D.C."),
        .init(
            "Banting", fullName: "Frederick Banting", field: "Medicine", years: "1891–1941",
            region: .northAmerica, gender: .man,
            note: "Canadian; co-found insulin"),
        .init(
            "Bari", fullName: "Nina Bari", field: "Mathematics", years: "1901–1961",
            region: .europe, gender: .woman,
            note: "Trigonometric series"),
        .init(
            "Barnard", fullName: "Christiaan Barnard", field: "Medicine", years: "1922–2001",
            region: .africa, gender: .man,
            note: "South African; first human heart transplant"),
        .init(
            "Barroso", fullName: "Graziela Barroso", field: "Biology", years: "1912–2003",
            region: .latinAmerica, gender: .woman,
            note: "Brazil's leading woman botanist"),
        .init(
            "Barré-Sinoussi", fullName: "Françoise Barré-Sinoussi", field: "Biology", years: "born 1947",
            isLiving: true,
            region: .europe, gender: .woman,
            note: "Co-found HIV; Nobel Prize"),
        .init(
            "Bartik", fullName: "Jean Bartik", field: "Computing", years: "1924–2011",
            region: .northAmerica, gender: .woman,
            note: "ENIAC programmer; stored-program conversion"),
        .init(
            "Bascom", fullName: "Florence Bascom", field: "Earth science", years: "1862–1945",
            region: .northAmerica, gender: .woman,
            note: "First woman geologist of the US Geological Survey"),
        .init(
            "Bassi", fullName: "Laura Bassi", field: "Physics", years: "1711–1778",
            region: .europe, gender: .woman,
            note: "First woman to hold a university chair in physics"),
        .init(
            "Bawendi", fullName: "Moungi Bawendi", field: "Chemistry", years: "born 1961", isLiving: true,
            region: .africa, gender: .man,
            note: "Tunisian-born; quantum dots; Nobel Prize"),
        .init(
            "Bayes", fullName: "Thomas Bayes", field: "Statistics", years: "1701–1761",
            region: .europe, gender: .man,
            note: "Bayes' theorem on conditional probability"),
        .init(
            "Begay", fullName: "Fred Begay", field: "Physics", years: "1932–2013",
            region: .northAmerica, gender: .man,
            note: "Navajo nuclear physicist; laser fusion research"),
        .init(
            "Bell Burnell", fullName: "Jocelyn Bell Burnell", field: "Astronomy", years: "born 1943", isLiving: true,
            region: .europe, gender: .woman,
            note: "Found the first pulsars; Breakthrough Prize"),
        .init(
            "Benacerraf", fullName: "Baruj Benacerraf", field: "Medicine", years: "1920–2011",
            region: .latinAmerica, gender: .man,
            note: "Venezuelan; genes that control the immune response"),
        .init(
            "Benerito", fullName: "Ruth Benerito", field: "Chemistry", years: "1916–2013",
            region: .northAmerica, gender: .woman,
            note: "Invented wrinkle-free cotton"),
        .init(
            "Berezin", fullName: "Evelyn Berezin", field: "Computing", years: "1925–2018",
            region: .northAmerica, gender: .woman,
            note: "Built the first computer word processor"),
        .init(
            "Bertozzi", fullName: "Carolyn Bertozzi", field: "Chemistry", years: "born 1966", isLiving: true,
            region: .northAmerica, gender: .woman,
            note: "Bioorthogonal chemistry; Nobel Prize"),
        .init(
            "Bhabha", fullName: "Homi J. Bhabha", field: "Physics", years: "1909–1966",
            region: .southAsia, gender: .man,
            note: "Electron–positron scattering; founded India's nuclear research"),
        .init(
            "Bhargava", fullName: "Manjul Bhargava", field: "Mathematics", years: "born 1974", isLiving: true,
            region: .southAsia, gender: .man,
            note: "Number theory; Fields Medal"),
        .init(
            "Bhatnagar", fullName: "Shanti Swarup Bhatnagar", field: "Chemistry", years: "1894–1955",
            region: .southAsia, gender: .man,
            note: "Magnetochemistry; founded India's national laboratories"),
        .init(
            "Bhāskara", fullName: "Bhāskara II", field: "Mathematics", years: "1114–1185",
            region: .southAsia, gender: .man,
            note: "Early ideas of calculus; the Lilavati"),
        .init(
            "Birkar", fullName: "Caucher Birkar", field: "Mathematics", years: "born 1978", isLiving: true,
            region: .westAndCentralAsia, gender: .man,
            note: "Kurdish mathematician; algebraic geometry; Fields Medal"),
        .init(
            "Blackburn", fullName: "Elizabeth Blackburn", field: "Biology", years: "born 1948", isLiving: true,
            region: .oceania, gender: .woman,
            note: "Australian; telomeres and telomerase; Nobel Prize"),
        .init(
            "Blackwell", fullName: "Elizabeth Blackwell and David Blackwell", field: "Medicine", years: "1821–2010",
            region: .northAmerica, gender: .woman,
            note: "First woman to earn an MD in the US (Elizabeth); see also the statistician David"),
        .init(
            "Blau", fullName: "Marietta Blau", field: "Physics", years: "1894–1970",
            region: .europe, gender: .woman,
            note: "Photographic method for tracking particles"),
        .init(
            "Blodgett", fullName: "Katharine Burr Blodgett", field: "Chemistry", years: "1898–1979",
            region: .northAmerica, gender: .woman,
            note: "Invented non-reflective glass"),
        .init(
            "Bohr", fullName: "Niels Bohr", field: "Physics", years: "1885–1962",
            region: .europe, gender: .man,
            note: "Quantum model of the atom"),
        .init(
            "Boltzmann", fullName: "Ludwig Boltzmann", field: "Physics", years: "1844–1906",
            region: .europe, gender: .man,
            note: "Founded statistical mechanics"),
        .init(
            "Boole", fullName: "George Boole", field: "Mathematics", years: "1815–1864",
            region: .europe, gender: .man,
            note: "Boolean algebra, the logic of computers"),
        .init(
            "Bose", fullName: "Jagadish Chandra Bose and Satyendra Nath Bose", field: "Physics", years: "1858–1974",
            region: .southAsia, gender: .man,
            note: "Microwave optics (J. C.); Bose–Einstein statistics (S. N.)"),
        .init(
            "Bouchet", fullName: "Edward Bouchet", field: "Physics", years: "1852–1918",
            region: .northAmerica, gender: .man,
            note: "First African American to earn a PhD, in physics"),
        .init(
            "Boykin", fullName: "Otis Boykin", field: "Engineering", years: "1920–1982",
            region: .northAmerica, gender: .man,
            note: "Invented resistors used in pacemakers and guided missiles"),
        .init(
            "Boyle", fullName: "Robert Boyle and Willard Boyle", field: "Physics", years: "1627–2011",
            region: .europe, gender: .man,
            note: "Gas law (Robert); the CCD image sensor (Willard, Canadian)"),
        .init(
            "Brahe", fullName: "Tycho Brahe", field: "Astronomy", years: "1546–1601",
            region: .europe, gender: .man,
            note: "Made the most precise naked-eye observations of the planets"),
        .init(
            "Brahmagupta", fullName: "Brahmagupta", field: "Mathematics", years: "598–668",
            region: .southAsia, gender: .man,
            note: "Rules for zero and negative numbers"),
        .init(
            "Brenner", fullName: "Sydney Brenner", field: "Biology", years: "1927–2019",
            region: .africa, gender: .man,
            note: "South African; messenger RNA and the genetic code"),
        .init(
            "Brockhouse", fullName: "Bertram Brockhouse", field: "Physics", years: "1918–2003",
            region: .northAmerica, gender: .man,
            note: "Canadian; neutron scattering"),
        .init(
            "Brooks", fullName: "Harriet Brooks", field: "Physics", years: "1876–1933",
            region: .northAmerica, gender: .woman,
            note: "Canada's first woman nuclear physicist; found radon recoil"),
        .init(
            "Browne", fullName: "Marjorie Lee Browne", field: "Mathematics", years: "1914–1979",
            region: .northAmerica, gender: .woman,
            note: "Matrix theory; early computing in mathematics education"),
        .init(
            "Bunsen", fullName: "Robert Bunsen", field: "Chemistry", years: "1811–1899",
            region: .europe, gender: .man,
            note: "Spectroscopy; the Bunsen burner"),
        .init(
            "Burbidge", fullName: "Margaret Burbidge", field: "Astronomy", years: "1919–2020",
            region: .europe, gender: .woman,
            note: "How stars make the chemical elements; quasars"),
        .init(
            "Cajal", fullName: "Santiago Ramón y Cajal", field: "Biology", years: "1852–1934",
            region: .europe, gender: .man,
            note: "Founded modern neuroscience; the neuron doctrine"),
        .init(
            "Caldas", fullName: "Francisco José de Caldas", field: "Earth science", years: "1768–1816",
            region: .latinAmerica, gender: .man,
            note: "Colombian; measured altitude from the boiling point of water"),
        .init(
            "Camarena", fullName: "Guillermo González Camarena", field: "Engineering", years: "1917–1965",
            region: .latinAmerica, gender: .man,
            note: "Mexican; invented a colour television system"),
        .init(
            "Cannon", fullName: "Annie Jump Cannon", field: "Astronomy", years: "1863–1941",
            region: .northAmerica, gender: .woman,
            note: "Made the system that classifies stars by spectrum"),
        .init(
            "Cantor", fullName: "Georg Cantor", field: "Mathematics", years: "1845–1918",
            region: .europe, gender: .man,
            note: "Set theory; sizes of infinity"),
        .init(
            "Carson", fullName: "Rachel Carson", field: "Biology", years: "1907–1964",
            region: .northAmerica, gender: .woman,
            note: "Silent Spring; started the environmental movement"),
        .init(
            "Cartwright", fullName: "Mary Cartwright", field: "Mathematics", years: "1900–1998",
            region: .europe, gender: .woman,
            note: "Early work in chaos theory"),
        .init(
            "Carver", fullName: "George Washington Carver", field: "Chemistry", years: "1864–1943",
            region: .northAmerica, gender: .man,
            note: "Agricultural chemist; crop rotation and soil health"),
        .init(
            "Chagas", fullName: "Carlos Chagas", field: "Medicine", years: "1879–1934",
            region: .latinAmerica, gender: .man,
            note: "Brazilian; described Chagas disease in full"),
        .init(
            "Chakravarty", fullName: "Charusita Chakravarty", field: "Chemistry", years: "1964–2016",
            region: .southAsia, gender: .woman,
            note: "Indian theoretical chemist; the structure of water and liquids"),
        .init(
            "Chandrasekhar", fullName: "Subrahmanyan Chandrasekhar", field: "Astronomy", years: "1910–1995",
            region: .southAsia, gender: .man,
            note: "The mass limit of white dwarf stars"),
        .init(
            "Charles Drew", fullName: "Charles R. Drew", field: "Medicine", years: "1904–1950",
            region: .northAmerica, gender: .man,
            note: "Developed large-scale blood banks"),
        .init(
            "Charpentier", fullName: "Emmanuelle Charpentier", field: "Biology", years: "born 1968", isLiving: true,
            region: .europe, gender: .woman,
            note: "CRISPR gene editing; Nobel Prize"),
        .init(
            "Chatterjee", fullName: "Asima Chatterjee and Rajeshwari Chatterjee", field: "Chemistry",
            years: "1917–2010",
            region: .southAsia, gender: .woman,
            note: "Plant-based drugs for epilepsy and malaria (Asima); microwave engineering (Rajeshwari)"),
        .init(
            "Chawla", fullName: "Kalpana Chawla", field: "Engineering", years: "1962–2003",
            region: .southAsia, gender: .woman,
            note: "Aerospace engineer and astronaut"),
        .init(
            "Chern", fullName: "Shiing-Shen Chern", field: "Mathematics", years: "1911–2004",
            region: .eastAsia, gender: .man,
            note: "Differential geometry; Chern classes"),
        .init(
            "Chien-Shiung Wu", fullName: "Chien-Shiung Wu", field: "Physics", years: "1912–1997",
            region: .eastAsia, gender: .woman,
            note: "Showed that parity is not conserved in weak interactions"),
        .init(
            "Chowdhuri", fullName: "Bibha Chowdhuri", field: "Physics", years: "1913–1991",
            region: .southAsia, gender: .woman,
            note: "Indian particle physicist; cosmic-ray research"),
        .init(
            "Châtelet", fullName: "Émilie du Châtelet", field: "Physics", years: "1706–1749",
            region: .europe, gender: .woman,
            note: "Translated and extended Newton's Principia; energy and kinetic force"),
        .init(
            "Clarke", fullName: "Edith Clarke and Joan Clarke", field: "Engineering", years: "1883–1996",
            region: .northAmerica, gender: .woman,
            note: "First US woman professor of electrical engineering (Edith); Enigma codebreaker (Joan)"),
        .init(
            "Conway", fullName: "John Horton Conway and Lynn Conway", field: "Mathematics", years: "1937–2024",
            region: .europe, gender: .man,
            note: "The Game of Life (John); VLSI chip design (Lynn)"),
        .init(
            "Copernicus", fullName: "Nicolaus Copernicus", field: "Astronomy", years: "1473–1543",
            region: .europe, gender: .man,
            note: "Proposed the heliocentric model of the solar system"),
        .init(
            "Cori", fullName: "Gerty Cori", field: "Biology", years: "1896–1957",
            region: .northAmerica, gender: .woman,
            note: "How the body stores and uses sugar"),
        .init(
            "Cormack", fullName: "Allan Cormack", field: "Medicine", years: "1924–1998",
            region: .africa, gender: .man,
            note: "South African; theory of the CT scan"),
        .init(
            "Coxeter", fullName: "H. S. M. Coxeter", field: "Mathematics", years: "1907–2003",
            region: .northAmerica, gender: .man,
            note: "Canadian; geometry and symmetry groups"),
        .init(
            "Crumpler", fullName: "Rebecca Lee Crumpler", field: "Medicine", years: "1831–1895",
            region: .northAmerica, gender: .woman,
            note: "First African American woman to earn an MD"),
        .init(
            "Curie", fullName: "Marie Skłodowska-Curie", field: "Physics", years: "1867–1934",
            region: .europe, gender: .woman,
            note: "Pioneer of radioactivity; Nobel Prizes in physics and chemistry"),
        .init(
            "Dalton", fullName: "John Dalton", field: "Chemistry", years: "1766–1844",
            region: .europe, gender: .man,
            note: "Atomic theory; studied colour blindness"),
        .init(
            "Daly", fullName: "Marie Maynard Daly", field: "Chemistry", years: "1921–2003",
            region: .northAmerica, gender: .woman,
            note: "First African American woman to earn a PhD in chemistry"),
        .init(
            "Darden", fullName: "Christine Darden", field: "Engineering", years: "born 1942", isLiving: true,
            region: .northAmerica, gender: .woman,
            note: "Research on sonic booms at NASA; Congressional Gold Medal"),
        .init(
            "Darwin", fullName: "Charles Darwin", field: "Biology", years: "1809–1882",
            region: .europe, gender: .man,
            note: "Evolution by natural selection"),
        .init(
            "Daubechies", fullName: "Ingrid Daubechies", field: "Mathematics", years: "born 1954", isLiving: true,
            region: .europe, gender: .woman,
            note: "Wavelets, used in image compression; Wolf Prize"),
        .init(
            "Davy", fullName: "Humphry Davy", field: "Chemistry", years: "1778–1829",
            region: .europe, gender: .man,
            note: "Isolated sodium and potassium by electrolysis; the miner's safety lamp"),
        .init(
            "Derick", fullName: "Carrie Derick", field: "Biology", years: "1862–1941",
            region: .northAmerica, gender: .woman,
            note: "Canada's first woman professor; botany and genetics at McGill"),
        .init(
            "Descartes", fullName: "René Descartes", field: "Mathematics", years: "1596–1650",
            region: .europe, gender: .man,
            note: "Coordinate geometry"),
        .init(
            "Dhawan", fullName: "Satish Dhawan", field: "Engineering", years: "1920–2002",
            region: .southAsia, gender: .man,
            note: "Led India's space program; fluid dynamics"),
        .init(
            "Dijkstra", fullName: "Edsger W. Dijkstra", field: "Computing", years: "1930–2002",
            region: .europe, gender: .man,
            note: "Shortest-path algorithm; structured programming"),
        .init(
            "Diop", fullName: "Cheikh Anta Diop", field: "Physics", years: "1923–1986",
            region: .africa, gender: .man,
            note: "Senegalese scientist; founded a radiocarbon laboratory in Dakar"),
        .init(
            "Dirac", fullName: "Paul Dirac", field: "Physics", years: "1902–1984",
            region: .europe, gender: .man,
            note: "Relativistic electron equation; predicted antimatter"),
        .init(
            "Doppler", fullName: "Christian Doppler", field: "Physics", years: "1803–1853",
            region: .europe, gender: .man,
            note: "The change in frequency of a moving source"),
        .init(
            "Doudna", fullName: "Jennifer Doudna", field: "Chemistry", years: "born 1964", isLiving: true,
            region: .northAmerica, gender: .woman,
            note: "CRISPR gene editing; Nobel Prize"),
        .init(
            "Döbereiner", fullName: "Johanna Döbereiner", field: "Biology", years: "1924–2000",
            region: .latinAmerica, gender: .woman,
            note: "Brazilian soil biologist; bacteria that fix nitrogen for crops"),
        .init(
            "Easley", fullName: "Annie Easley", field: "Computing", years: "1933–2011",
            region: .northAmerica, gender: .woman,
            note: "NASA programmer; the Centaur rocket stage"),
        .init(
            "Eastwood", fullName: "Alice Eastwood", field: "Biology", years: "1859–1953",
            region: .northAmerica, gender: .woman,
            note: "Canadian-born botanist; saved the type specimens in the 1906 San Francisco fire"),
        .init(
            "Eccles", fullName: "John Eccles", field: "Biology", years: "1903–1997",
            region: .oceania, gender: .man,
            note: "Australian; how nerve cells signal at synapses"),
        .init(
            "Einstein", fullName: "Albert Einstein", field: "Physics", years: "1879–1955",
            region: .europe, gender: .man,
            note: "Relativity; the photoelectric effect"),
        .init(
            "Elion", fullName: "Gertrude B. Elion", field: "Chemistry", years: "1918–1999",
            region: .northAmerica, gender: .woman,
            note: "Designed drugs for leukemia, gout and transplant rejection"),
        .init(
            "Engelbart", fullName: "Douglas Engelbart", field: "Computing", years: "1925–2013",
            region: .northAmerica, gender: .man,
            note: "The computer mouse; hypertext and the \"mother of all demos\""),
        .init(
            "Eratosthenes", fullName: "Eratosthenes of Cyrene", field: "Astronomy", years: "c. 276–c. 194 BCE",
            region: .africa, gender: .man,
            note: "Measured the circumference of the Earth from shadows"),
        .init(
            "Erdős", fullName: "Paul Erdős", field: "Mathematics", years: "1913–1996",
            region: .europe, gender: .man,
            note: "Combinatorics; more than 1,500 papers"),
        .init(
            "Ernest Just", fullName: "Ernest Everett Just", field: "Biology", years: "1883–1941",
            region: .northAmerica, gender: .man,
            note: "Cell biology; the role of the cell surface in development"),
        .init(
            "Erxleben", fullName: "Dorothea Erxleben", field: "Medicine", years: "1715–1762",
            region: .europe, gender: .woman,
            note: "First woman to earn an MD in Germany"),
        .init(
            "Estrin", fullName: "Thelma Estrin", field: "Computing", years: "1924–2014",
            region: .northAmerica, gender: .woman,
            note: "Pioneer of computers in biomedical research"),
        .init(
            "Euclid", fullName: "Euclid of Alexandria", field: "Mathematics", years: "c. 325–c. 265 BCE",
            region: .africa, gender: .man,
            note: "The Elements, the model for mathematical proof"),
        .init(
            "Euler", fullName: "Leonhard Euler", field: "Mathematics", years: "1707–1783",
            region: .europe, gender: .man,
            note: "Graph theory; the notation e, i and f(x)"),
        .init(
            "Faraday", fullName: "Michael Faraday", field: "Physics", years: "1791–1867",
            region: .europe, gender: .man,
            note: "Electromagnetic induction; the electric motor and dynamo"),
        .init(
            "Fermat", fullName: "Pierre de Fermat", field: "Mathematics", years: "1607–1665",
            region: .europe, gender: .man,
            note: "Number theory; Fermat's last theorem"),
        .init(
            "Fermi", fullName: "Enrico Fermi", field: "Physics", years: "1901–1954",
            region: .europe, gender: .man,
            note: "First nuclear reactor; Fermi–Dirac statistics"),
        .init(
            "Fessenden", fullName: "Reginald Fessenden", field: "Engineering", years: "1866–1932",
            region: .northAmerica, gender: .man,
            note: "Canadian; first radio broadcast of voice and music"),
        .init(
            "Feynman", fullName: "Richard Feynman", field: "Physics", years: "1918–1988",
            region: .northAmerica, gender: .man,
            note: "Quantum electrodynamics; Feynman diagrams"),
        .init(
            "Fibonacci", fullName: "Leonardo of Pisa", field: "Mathematics", years: "c. 1170–c. 1250",
            region: .europe, gender: .man,
            note: "Brought Hindu–Arabic numerals to Europe"),
        .init(
            "Finlay", fullName: "Carlos Finlay", field: "Medicine", years: "1833–1915",
            region: .latinAmerica, gender: .man,
            note: "Cuban; showed that mosquitoes carry yellow fever"),
        .init(
            "Fleming", fullName: "Alexander Fleming and Williamina Fleming", field: "Medicine", years: "1857–1955",
            region: .europe, gender: .both,
            note: "Found penicillin (Alexander); classified 10,000 stars and found the Horsehead Nebula (Williamina)"),
        .init(
            "Florey", fullName: "Howard Florey", field: "Medicine", years: "1898–1968",
            region: .oceania, gender: .man,
            note: "Australian; made penicillin into a drug"),
        .init(
            "Foote", fullName: "Eunice Newton Foote", field: "Earth science", years: "1819–1888",
            region: .northAmerica, gender: .woman,
            note: "First showed that carbon dioxide traps heat"),
        .init(
            "Forsythe", fullName: "Alexandra Illmer Forsythe", field: "Computing", years: "1918–1980",
            region: .northAmerica, gender: .woman,
            note: "Wrote early computer science textbooks"),
        .init(
            "Fourier", fullName: "Joseph Fourier", field: "Mathematics", years: "1768–1830",
            region: .europe, gender: .man,
            note: "Fourier series; heat flow"),
        .init(
            "Franklin", fullName: "Rosalind Franklin", field: "Chemistry", years: "1920–1958",
            region: .europe, gender: .woman,
            note: "X-ray images that showed the structure of DNA"),
        .init(
            "Fukui", fullName: "Kenichi Fukui", field: "Chemistry", years: "1918–1998",
            region: .eastAsia, gender: .man,
            note: "Frontier orbital theory"),
        .init(
            "Galen", fullName: "Galen of Pergamon", field: "Medicine", years: "129–c. 216",
            region: .westAndCentralAsia, gender: .man,
            note: "Anatomy and physiology for the next thirteen centuries"),
        .init(
            "Galileo", fullName: "Galileo Galilei", field: "Physics", years: "1564–1642",
            region: .europe, gender: .man,
            note: "Used the telescope for astronomy; studied motion and falling bodies"),
        .init(
            "Galois", fullName: "Évariste Galois", field: "Mathematics", years: "1811–1832",
            region: .europe, gender: .man,
            note: "Group theory and the solvability of equations"),
        .init(
            "Ganguly", fullName: "Kadambini Ganguly", field: "Medicine", years: "1861–1923",
            region: .southAsia, gender: .woman,
            note: "One of the first Indian women to practise Western medicine"),
        .init(
            "Gauss", fullName: "Carl Friedrich Gauss", field: "Mathematics", years: "1777–1855",
            region: .europe, gender: .man,
            note: "Number theory; the normal distribution"),
        .init(
            "Geiringer", fullName: "Hilda Geiringer", field: "Mathematics", years: "1893–1973",
            region: .europe, gender: .woman,
            note: "Plasticity theory and probability"),
        .init(
            "Germain", fullName: "Sophie Germain", field: "Mathematics", years: "1776–1831",
            region: .europe, gender: .woman,
            note: "Elasticity theory; work toward Fermat's last theorem"),
        .init(
            "Ghez", fullName: "Andrea Ghez", field: "Astronomy", years: "born 1965", isLiving: true,
            region: .northAmerica, gender: .woman,
            note: "The black hole at the centre of the Milky Way; Nobel Prize"),
        .init(
            "Gilbreth", fullName: "Lillian Moller Gilbreth", field: "Engineering", years: "1878–1972",
            region: .northAmerica, gender: .woman,
            note: "Industrial engineering and ergonomics"),
        .init(
            "Gleditsch", fullName: "Ellen Gleditsch", field: "Chemistry", years: "1879–1968",
            region: .europe, gender: .woman,
            note: "Norwegian radiochemist; measured the half-life of radium"),
        .init(
            "Godbole", fullName: "Rohini Godbole", field: "Physics", years: "1952–2024",
            region: .southAsia, gender: .woman,
            note: "Indian particle physicist; worked for more women in science"),
        .init(
            "Goeppert Mayer", fullName: "Maria Goeppert Mayer", field: "Physics", years: "1906–1972",
            region: .northAmerica, gender: .woman,
            note: "Nuclear shell model"),
        .init(
            "Goldstine", fullName: "Adele Goldstine", field: "Computing", years: "1920–1964",
            region: .northAmerica, gender: .woman,
            note: "Wrote the ENIAC manual; trained its programmers"),
        .init(
            "Goldwasser", fullName: "Shafi Goldwasser", field: "Computing", years: "born 1958", isLiving: true,
            region: .westAndCentralAsia, gender: .woman,
            note: "Cryptography and zero-knowledge proofs; Turing Award"),
        .init(
            "Goodall", fullName: "Jane Goodall", field: "Biology", years: "1934–2025",
            region: .europe, gender: .woman,
            note: "Chimpanzee behaviour; showed that animals make and use tools"),
        .init(
            "Granville", fullName: "Evelyn Boyd Granville", field: "Mathematics", years: "1924–2023",
            region: .northAmerica, gender: .woman,
            note: "Orbit calculations for NASA's early space programs"),
        .init(
            "Greider", fullName: "Carol Greider", field: "Biology", years: "born 1961", isLiving: true,
            region: .northAmerica, gender: .woman,
            note: "Co-found telomerase; Nobel Prize"),
        .init(
            "Grierson", fullName: "Cecilia Grierson", field: "Medicine", years: "1859–1934",
            region: .latinAmerica, gender: .woman,
            note: "First woman physician in Argentina"),
        .init(
            "Gödel", fullName: "Kurt Gödel", field: "Mathematics", years: "1906–1978",
            region: .europe, gender: .man,
            note: "Incompleteness theorems"),
        .init(
            "Hamilton", fullName: "William Rowan Hamilton and Margaret Hamilton", field: "Mathematics",
            years: "1805–1865",
            region: .europe, gender: .both,
            note:
                "Quaternions (William Rowan); led the Apollo flight software and named software engineering (Margaret, alive)"
        ),
        .init(
            "Hamming", fullName: "Richard Hamming", field: "Computing", years: "1915–1998",
            region: .northAmerica, gender: .man,
            note: "Error-correcting codes"),
        .init(
            "Harish-Chandra", fullName: "Harish-Chandra", field: "Mathematics", years: "1923–1983",
            region: .southAsia, gender: .man,
            note: "Representation theory of Lie groups"),
        .init(
            "Haro", fullName: "Guillermo Haro", field: "Astronomy", years: "1913–1988",
            region: .latinAmerica, gender: .man,
            note: "Mexican; Herbig–Haro objects and flare stars"),
        .init(
            "Haslett", fullName: "Caroline Haslett", field: "Engineering", years: "1895–1957",
            region: .europe, gender: .woman,
            note: "Electrical engineer; founded the Electrical Association for Women"),
        .init(
            "Hata", fullName: "Sahachirō Hata", field: "Medicine", years: "1873–1938",
            region: .eastAsia, gender: .man,
            note: "Co-found the first drug for syphilis"),
        .init(
            "Hawking", fullName: "Stephen Hawking", field: "Physics", years: "1942–2018",
            region: .europe, gender: .man,
            note: "Black-hole radiation; cosmology"),
        .init(
            "Haynes", fullName: "Euphemia Lofton Haynes", field: "Mathematics", years: "1890–1980",
            region: .northAmerica, gender: .woman,
            note: "First African American woman to earn a PhD in mathematics"),
        .init(
            "Hazen", fullName: "Elizabeth Lee Hazen", field: "Biology", years: "1885–1975",
            region: .northAmerica, gender: .woman,
            note: "Co-found nystatin, the first antifungal antibiotic"),
        .init(
            "He Zehui", fullName: "He Zehui", field: "Physics", years: "1914–2011",
            region: .eastAsia, gender: .woman,
            note: "Chinese nuclear physicist; found the four-way fission of uranium"),
        .init(
            "Hermann", fullName: "Grete Hermann", field: "Mathematics", years: "1901–1984",
            region: .europe, gender: .woman,
            note: "Algorithms in algebra; foundations of quantum mechanics"),
        .init(
            "Herschel", fullName: "Caroline Herschel", field: "Astronomy", years: "1750–1848",
            region: .europe, gender: .woman,
            note: "Found eight comets; first woman paid as a scientist in Britain"),
        .init(
            "Hertz", fullName: "Heinrich Hertz", field: "Physics", years: "1857–1894",
            region: .europe, gender: .man,
            note: "Proved that electromagnetic waves exist"),
        .init(
            "Herzberg", fullName: "Gerhard Herzberg", field: "Physics", years: "1904–1999",
            region: .northAmerica, gender: .man,
            note: "Canadian; molecular spectroscopy and free radicals"),
        .init(
            "Hidalgo", fullName: "Matilde Hidalgo", field: "Medicine", years: "1889–1974",
            region: .latinAmerica, gender: .woman,
            note: "First woman physician in Ecuador"),
        .init(
            "Hilbert", fullName: "David Hilbert", field: "Mathematics", years: "1862–1943",
            region: .europe, gender: .man,
            note: "Hilbert spaces; the 23 problems"),
        .init(
            "Hippocrates", fullName: "Hippocrates of Kos", field: "Medicine", years: "c. 460–c. 370 BCE",
            region: .europe, gender: .man,
            note: "Founded medicine as a profession separate from religion"),
        .init(
            "Hodgkin", fullName: "Dorothy Crowfoot Hodgkin", field: "Chemistry", years: "1910–1994",
            region: .europe, gender: .woman,
            note: "Structures of penicillin, vitamin B12 and insulin"),
        .init(
            "Holberton", fullName: "Betty Holberton", field: "Computing", years: "1917–2001",
            region: .northAmerica, gender: .woman,
            note: "ENIAC programmer; early sort-merge generator"),
        .init(
            "Honjo", fullName: "Tasuku Honjo", field: "Medicine", years: "born 1942", isLiving: true,
            region: .eastAsia, gender: .man,
            note: "Found PD-1, the basis of cancer immunotherapy; Nobel Prize"),
        .init(
            "Hopper", fullName: "Grace Hopper", field: "Computing", years: "1906–1992",
            region: .northAmerica, gender: .woman,
            note: "First compiler; COBOL"),
        .init(
            "Houssay", fullName: "Bernardo Houssay", field: "Medicine", years: "1887–1971",
            region: .latinAmerica, gender: .man,
            note: "Argentine; role of the pituitary in sugar metabolism"),
        .init(
            "Hua Luogeng", fullName: "Hua Luogeng", field: "Mathematics", years: "1910–1985",
            region: .eastAsia, gender: .man,
            note: "Number theory; taught applied mathematics across China"),
        .init(
            "Hubble", fullName: "Edwin Hubble", field: "Astronomy", years: "1889–1953",
            region: .northAmerica, gender: .man,
            note: "Showed that the universe expands"),
        .init(
            "Humboldt", fullName: "Alexander von Humboldt", field: "Earth science", years: "1769–1859",
            region: .europe, gender: .man,
            note: "Founded biogeography; climate zones"),
        .init(
            "Hyde", fullName: "Ida Hyde", field: "Biology", years: "1857–1945",
            region: .northAmerica, gender: .woman,
            note: "Physiologist; developed the microelectrode"),
        .init(
            "Hyman", fullName: "Libbie Hyman", field: "Biology", years: "1888–1969",
            region: .northAmerica, gender: .woman,
            note: "Wrote the standard reference on invertebrate animals"),
        .init(
            "Hypatia", fullName: "Hypatia of Alexandria", field: "Astronomy", years: "c. 360–415",
            region: .africa, gender: .woman,
            note: "Taught mathematics and astronomy in Alexandria"),
        .init(
            "Ibn Sīnā", fullName: "Ibn Sina (Avicenna)", field: "Medicine", years: "980–1037",
            region: .westAndCentralAsia, gender: .man,
            note: "The Canon of Medicine, a standard text for 600 years"),
        .init(
            "Ikeda", fullName: "Kikunae Ikeda", field: "Chemistry", years: "1864–1936",
            region: .eastAsia, gender: .man,
            note: "Found umami, the fifth taste"),
        .init(
            "Imes", fullName: "Elmer Imes", field: "Physics", years: "1883–1941",
            region: .northAmerica, gender: .man,
            note: "Infrared spectra that confirmed quantum theory for molecules"),
        .init(
            "Immerwahr", fullName: "Clara Immerwahr", field: "Chemistry", years: "1870–1915",
            region: .europe, gender: .woman,
            note: "First woman to earn a doctorate in chemistry in Germany"),
        .init(
            "Ionescu", fullName: "Sofia Ionescu", field: "Medicine", years: "1920–2008",
            region: .europe, gender: .woman,
            note: "One of the first women neurosurgeons"),
        .init(
            "Ito", fullName: "Kiyosi Itô", field: "Mathematics", years: "1915–2008",
            region: .eastAsia, gender: .man,
            note: "Stochastic calculus"),
        .init(
            "Iwasawa", fullName: "Kenkichi Iwasawa", field: "Mathematics", years: "1917–1998",
            region: .eastAsia, gender: .man,
            note: "Iwasawa theory in number theory"),
        .init(
            "Jacquard", fullName: "Joseph Marie Jacquard", field: "Engineering", years: "1752–1834",
            region: .europe, gender: .man,
            note: "Punched-card loom, an ancestor of programming"),
        .init(
            "Janaki Ammal", fullName: "E. K. Janaki Ammal", field: "Biology", years: "1897–1984",
            region: .southAsia, gender: .woman,
            note: "Plant geneticist; bred sweet sugarcane"),
        .init(
            "Jang Yeong-sil", fullName: "Jang Yeong-sil", field: "Engineering", years: "c. 1390–c. 1450",
            region: .eastAsia, gender: .man,
            note: "Korean engineer; built water clocks and the first rain gauges"),
        .init(
            "Javan", fullName: "Ali Javan", field: "Physics", years: "1926–2016",
            region: .westAndCentralAsia, gender: .man,
            note: "Iranian American; invented the gas laser"),
        .init(
            "Jemison", fullName: "Mae Jemison", field: "Engineering", years: "born 1956", isLiving: true,
            region: .northAmerica, gender: .woman,
            note: "Engineer and physician; first Black woman in space"),
        .init(
            "Jenner", fullName: "Edward Jenner", field: "Medicine", years: "1749–1823",
            region: .europe, gender: .man,
            note: "Made the first vaccine, against smallpox"),
        .init(
            "Jex-Blake", fullName: "Sophia Jex-Blake", field: "Medicine", years: "1840–1912",
            region: .europe, gender: .woman,
            note: "Opened medical education to women in the UK"),
        .init(
            "Johnson", fullName: "Katherine Johnson", field: "Mathematics", years: "1918–2020",
            region: .northAmerica, gender: .woman,
            note: "Calculated the trajectories for NASA's first crewed flights"),
        .init(
            "Joliot-Curie", fullName: "Irène Joliot-Curie", field: "Chemistry", years: "1897–1956",
            region: .europe, gender: .woman,
            note: "Made the first artificial radioactive elements"),
        .init(
            "Joshi", fullName: "Anandibai Joshi", field: "Medicine", years: "1865–1887",
            region: .southAsia, gender: .woman,
            note: "One of the first Indian women to earn a medical degree"),
        .init(
            "Joule", fullName: "James Prescott Joule", field: "Physics", years: "1818–1889",
            region: .europe, gender: .man,
            note: "Showed that heat is a form of energy"),
        .init(
            "Kalam", fullName: "A. P. J. Abdul Kalam", field: "Engineering", years: "1931–2015",
            region: .southAsia, gender: .man,
            note: "Aerospace engineer; India's launch vehicles"),
        .init(
            "Kang", fullName: "Gagandeep Kang", field: "Medicine", years: "born 1962", isLiving: true,
            region: .southAsia, gender: .woman,
            note: "Indian virologist; rotavirus vaccines; Fellow of the Royal Society"),
        .init(
            "Karikó", fullName: "Katalin Karikó", field: "Biology", years: "born 1955", isLiving: true,
            region: .europe, gender: .woman,
            note: "Modified mRNA for vaccines; Nobel Prize"),
        .init(
            "Karlik", fullName: "Berta Karlik", field: "Physics", years: "1904–1990",
            region: .europe, gender: .woman,
            note: "Found natural astatine"),
        .init(
            "Keller", fullName: "Mary Kenneth Keller", field: "Computing", years: "1913–1985",
            region: .northAmerica, gender: .woman,
            note: "One of the first people to earn a PhD in computer science in the US"),
        .init(
            "Kelvin", fullName: "William Thomson, Lord Kelvin", field: "Physics", years: "1824–1907",
            region: .europe, gender: .man,
            note: "Absolute temperature scale; transatlantic telegraph"),
        .init(
            "Kepler", fullName: "Johannes Kepler", field: "Astronomy", years: "1571–1630",
            region: .europe, gender: .man,
            note: "Found the three laws of planetary motion"),
        .init(
            "Khayyam", fullName: "Omar Khayyam", field: "Mathematics", years: "1048–1131",
            region: .westAndCentralAsia, gender: .man,
            note: "Solved cubic equations with geometry; reformed the calendar"),
        .init(
            "Khorana", fullName: "Har Gobind Khorana", field: "Biology", years: "1922–2011",
            region: .southAsia, gender: .man,
            note: "Decoded the genetic code; made the first synthetic gene"),
        .init(
            "Kimmerer", fullName: "Robin Wall Kimmerer", field: "Biology", years: "born 1953", isLiving: true,
            region: .northAmerica, gender: .woman,
            note: "Potawatomi botanist; moss ecology and Indigenous knowledge; MacArthur Fellowship"),
        .init(
            "Kimura", fullName: "Motoo Kimura", field: "Biology", years: "1924–1994",
            region: .eastAsia, gender: .man,
            note: "Neutral theory of molecular evolution"),
        .init(
            "Kitasato", fullName: "Kitasato Shibasaburō", field: "Medicine", years: "1853–1931",
            region: .eastAsia, gender: .man,
            note: "Grew the tetanus bacillus; co-found antitoxin therapy"),
        .init(
            "Klug", fullName: "Aaron Klug", field: "Chemistry", years: "1926–2018",
            region: .africa, gender: .man,
            note: "Raised in South Africa; crystallographic electron microscopy"),
        .init(
            "Kodaira", fullName: "Kunihiko Kodaira", field: "Mathematics", years: "1915–1997",
            region: .eastAsia, gender: .man,
            note: "Complex manifolds; first Fields Medal from Japan"),
        .init(
            "Kolmogorov", fullName: "Andrey Kolmogorov", field: "Mathematics", years: "1903–1987",
            region: .europe, gender: .man,
            note: "Axioms of probability"),
        .init(
            "Koshiba", fullName: "Masatoshi Koshiba", field: "Physics", years: "1926–2020",
            region: .eastAsia, gender: .man,
            note: "Detected neutrinos from a supernova"),
        .init(
            "Kovalevskaya", fullName: "Sofya Kovalevskaya", field: "Mathematics", years: "1850–1891",
            region: .europe, gender: .woman,
            note: "Partial differential equations; first woman with a full professorship in Northern Europe"),
        .init(
            "Kurien", fullName: "Verghese Kurien", field: "Engineering", years: "1921–2012",
            region: .southAsia, gender: .man,
            note: "Engineer who led India's milk revolution"),
        .init(
            "Kuroda", fullName: "Chika Kuroda", field: "Chemistry", years: "1884–1968",
            region: .eastAsia, gender: .woman,
            note: "First Japanese woman to earn a science degree; natural dyes"),
        .init(
            "Kwolek", fullName: "Stephanie Kwolek", field: "Chemistry", years: "1923–2014",
            region: .northAmerica, gender: .woman,
            note: "Invented Kevlar"),
        .init(
            "Ladyzhenskaya", fullName: "Olga Ladyzhenskaya", field: "Mathematics", years: "1922–2004",
            region: .europe, gender: .woman,
            note: "Partial differential equations; fluid dynamics"),
        .init(
            "Lamarr", fullName: "Hedy Lamarr", field: "Engineering", years: "1914–2000",
            region: .europe, gender: .woman,
            note: "Co-invented frequency hopping for secure radio"),
        .init(
            "Lambek", fullName: "Joachim Lambek", field: "Mathematics", years: "1922–2014",
            region: .northAmerica, gender: .man,
            note: "Canadian; category theory and the Lambek calculus"),
        .init(
            "Lambo", fullName: "Thomas Adeoye Lambo", field: "Medicine", years: "1923–2004",
            region: .africa, gender: .man,
            note: "Nigerian psychiatrist; community-based mental health care"),
        .init(
            "Laplace", fullName: "Pierre-Simon Laplace", field: "Mathematics", years: "1749–1827",
            region: .europe, gender: .man,
            note: "Celestial mechanics; probability theory"),
        .init(
            "Latimer", fullName: "Lewis Howard Latimer", field: "Engineering", years: "1848–1928",
            region: .northAmerica, gender: .man,
            note: "Improved the carbon filament of the light bulb"),
        .init(
            "Lattes", fullName: "César Lattes", field: "Physics", years: "1924–2005",
            region: .latinAmerica, gender: .man,
            note: "Co-found the pion"),
        .init(
            "Lavoisier", fullName: "Antoine and Marie-Anne Lavoisier", field: "Chemistry", years: "1743–1836",
            region: .europe, gender: .man,
            note: "Named oxygen and hydrogen; conservation of mass"),
        .init(
            "Leavitt", fullName: "Henrietta Swan Leavitt", field: "Astronomy", years: "1868–1921",
            region: .northAmerica, gender: .woman,
            note: "Found the period–luminosity relation that measures cosmic distance"),
        .init(
            "Lederberg", fullName: "Esther Lederberg", field: "Biology", years: "1922–2006",
            region: .northAmerica, gender: .woman,
            note: "Found the lambda phage; replica plating"),
        .init(
            "Leeuwenhoek", fullName: "Antonie van Leeuwenhoek", field: "Biology", years: "1632–1723",
            region: .europe, gender: .man,
            note: "Saw bacteria and other microbes for the first time"),
        .init(
            "Lehmann", fullName: "Inge Lehmann", field: "Earth science", years: "1888–1993",
            region: .europe, gender: .woman,
            note: "Found the solid inner core of the Earth"),
        .init(
            "Leibniz", fullName: "Gottfried Wilhelm Leibniz", field: "Mathematics", years: "1646–1716",
            region: .europe, gender: .man,
            note: "Calculus notation; binary numbers"),
        .init(
            "Leloir", fullName: "Luis Federico Leloir", field: "Chemistry", years: "1906–1987",
            region: .latinAmerica, gender: .man,
            note: "Argentine; how cells make sugars"),
        .init(
            "Lemaître", fullName: "Georges Lemaître", field: "Astronomy", years: "1894–1966",
            region: .europe, gender: .man,
            note: "Proposed the expanding universe and the primeval atom"),
        .init(
            "Levi-Montalcini", fullName: "Rita Levi-Montalcini", field: "Biology", years: "1909–2012",
            region: .europe, gender: .woman,
            note: "Found nerve growth factor"),
        .init(
            "Lin Qiaozhi", fullName: "Lin Qiaozhi", field: "Medicine", years: "1901–1983",
            region: .eastAsia, gender: .woman,
            note: "Founded modern obstetrics and gynaecology in China"),
        .init(
            "Lister", fullName: "Joseph Lister", field: "Medicine", years: "1827–1912",
            region: .europe, gender: .man,
            note: "Antiseptic surgery"),
        .init(
            "Lonsdale", fullName: "Kathleen Lonsdale", field: "Chemistry", years: "1903–1971",
            region: .europe, gender: .woman,
            note: "Showed that the benzene ring is flat"),
        .init(
            "Lovelace", fullName: "Ada Lovelace", field: "Computing", years: "1815–1852",
            region: .europe, gender: .woman,
            note: "Wrote the first published computer program"),
        .init(
            "Luisi", fullName: "Paulina Luisi", field: "Medicine", years: "1875–1950",
            region: .latinAmerica, gender: .woman,
            note: "First woman physician in Uruguay"),
        .init(
            "Lutz", fullName: "Adolfo Lutz and Bertha Lutz", field: "Medicine", years: "1855–1976",
            region: .latinAmerica, gender: .both,
            note: "Tropical medicine (Adolfo); zoology and women's rights (Bertha)"),
        .init(
            "Lyell", fullName: "Charles Lyell", field: "Earth science", years: "1797–1875",
            region: .europe, gender: .man,
            note: "Principles of Geology"),
        .init(
            "Maathai", fullName: "Wangari Maathai", field: "Biology", years: "1940–2011",
            region: .africa, gender: .woman,
            note: "Founded the Green Belt Movement; Nobel Peace Prize"),
        .init(
            "MacGill", fullName: "Elsie MacGill", field: "Engineering", years: "1905–1980",
            region: .northAmerica, gender: .woman,
            note: "Canadian; first woman aircraft designer"),
        .init(
            "Mahalanobis", fullName: "Prasanta Chandra Mahalanobis", field: "Statistics", years: "1893–1972",
            region: .southAsia, gender: .man,
            note: "Mahalanobis distance; founded the Indian Statistical Institute"),
        .init(
            "Mandelbrot", fullName: "Benoit Mandelbrot", field: "Mathematics", years: "1924–2010",
            region: .europe, gender: .man,
            note: "Fractal geometry"),
        .init(
            "Mani", fullName: "Anna Mani", field: "Earth science", years: "1918–2001",
            region: .southAsia, gender: .woman,
            note: "Indian meteorologist; instruments for solar radiation and ozone"),
        .init(
            "Marić", fullName: "Mileva Marić", field: "Physics", years: "1875–1948",
            region: .europe, gender: .woman,
            note: "Serbian physicist and mathematician; one of the first women to study physics in Zurich"),
        .init(
            "Markov", fullName: "Andrey Markov", field: "Mathematics", years: "1856–1922",
            region: .europe, gender: .man,
            note: "Markov chains"),
        .init(
            "Mary Jackson", fullName: "Mary Jackson", field: "Engineering", years: "1921–2005",
            region: .northAmerica, gender: .woman,
            note: "NASA's first Black woman engineer; aerodynamics"),
        .init(
            "Maskawa", fullName: "Toshihide Maskawa", field: "Physics", years: "1940–2021",
            region: .eastAsia, gender: .man,
            note: "Predicted a third family of quarks"),
        .init(
            "Matzeliger", fullName: "Jan Ernst Matzeliger", field: "Engineering", years: "1852–1889",
            region: .latinAmerica, gender: .man,
            note: "Born in Suriname; invented the shoe-lasting machine"),
        .init(
            "Maunder", fullName: "Annie Maunder", field: "Astronomy", years: "1868–1947",
            region: .europe, gender: .woman,
            note: "Solar astronomer; photographed the solar corona and sunspot cycles"),
        .init(
            "Mavalvala", fullName: "Nergis Mavalvala", field: "Physics", years: "born 1968", isLiving: true,
            region: .southAsia, gender: .woman,
            note: "Pakistani American; detected gravitational waves at LIGO; MacArthur Fellowship"),
        .init(
            "Maxwell", fullName: "James Clerk Maxwell", field: "Physics", years: "1831–1879",
            region: .europe, gender: .man,
            note: "Equations that unite electricity, magnetism and light"),
        .init(
            "McClintock", fullName: "Barbara McClintock", field: "Biology", years: "1902–1992",
            region: .northAmerica, gender: .woman,
            note: "Found genes that move: transposons"),
        .init(
            "McCoy", fullName: "Elijah McCoy", field: "Engineering", years: "1844–1929",
            region: .northAmerica, gender: .man,
            note: "Canadian-born; automatic lubricators for steam engines"),
        .init(
            "McLaren", fullName: "Anne McLaren", field: "Biology", years: "1927–2007",
            region: .europe, gender: .woman,
            note: "Developmental biology; work that led to IVF"),
        .init(
            "Meitner", fullName: "Lise Meitner", field: "Physics", years: "1878–1968",
            region: .europe, gender: .woman,
            note: "Explained nuclear fission"),
        .init(
            "Meltzer", fullName: "Marlyn Meltzer", field: "Computing", years: "1922–2008",
            region: .northAmerica, gender: .woman,
            note: "ENIAC programmer"),
        .init(
            "Mendel", fullName: "Gregor Mendel", field: "Biology", years: "1822–1884",
            region: .europe, gender: .man,
            note: "Founded genetics with experiments on peas"),
        .init(
            "Mendeleev", fullName: "Dmitri Mendeleev", field: "Chemistry", years: "1834–1907",
            region: .europe, gender: .man,
            note: "The periodic table of the elements"),
        .init(
            "Merian", fullName: "Maria Sibylla Merian", field: "Biology", years: "1647–1717",
            region: .europe, gender: .woman,
            note: "Observed and drew the life cycles of insects"),
        .init(
            "Mexía", fullName: "Ynés Mexía", field: "Biology", years: "1870–1938",
            region: .latinAmerica, gender: .woman,
            note: "Mexican American botanist; collected 145,000 plant specimens"),
        .init(
            "Milanković", fullName: "Milutin Milanković", field: "Earth science", years: "1879–1958",
            region: .europe, gender: .man,
            note: "Orbital cycles that drive the ice ages"),
        .init(
            "Milstein", fullName: "César Milstein", field: "Biology", years: "1927–2002",
            region: .latinAmerica, gender: .man,
            note: "Argentine; monoclonal antibodies"),
        .init(
            "Mirzakhani", fullName: "Maryam Mirzakhani", field: "Mathematics", years: "1977–2017",
            region: .westAndCentralAsia, gender: .woman,
            note: "Geometry of Riemann surfaces; first woman to win the Fields Medal"),
        .init(
            "Mitchell", fullName: "Maria Mitchell", field: "Astronomy", years: "1818–1889",
            region: .northAmerica, gender: .woman,
            note: "First professional woman astronomer in the United States"),
        .init(
            "Mohorovičić", fullName: "Andrija Mohorovičić", field: "Earth science", years: "1857–1936",
            region: .europe, gender: .man,
            note: "Found the boundary between the crust and the mantle"),
        .init(
            "Molina", fullName: "Mario Molina", field: "Chemistry", years: "1943–2020",
            region: .latinAmerica, gender: .man,
            note: "Mexican; showed that CFCs destroy the ozone layer"),
        .init(
            "Morawetz", fullName: "Cathleen Synge Morawetz", field: "Mathematics", years: "1923–2017",
            region: .northAmerica, gender: .woman,
            note: "Canadian-born; shock waves and transonic flow"),
        .init(
            "Moser", fullName: "May-Britt Moser and Edvard Moser", field: "Biology", years: "born 1962", isLiving: true,
            region: .europe, gender: .both,
            note: "Grid cells, the brain's positioning system; Nobel Prize"),
        .init(
            "Mosharafa", fullName: "Ali Moustafa Mosharafa", field: "Physics", years: "1898–1950",
            region: .africa, gender: .man,
            note: "Egyptian physicist; quantum theory and relativity"),
        .init(
            "Moufang", fullName: "Ruth Moufang", field: "Mathematics", years: "1905–1977",
            region: .europe, gender: .woman,
            note: "Moufang planes and loops"),
        .init(
            "Moumouni", fullName: "Abdou Moumouni Dioffo", field: "Physics", years: "1929–1991",
            region: .africa, gender: .man,
            note: "Nigerien physicist; pioneer of solar energy in Africa"),
        .init(
            "Moussa", fullName: "Sameera Moussa", field: "Physics", years: "1917–1952",
            region: .africa, gender: .woman,
            note: "Egyptian nuclear physicist; worked for the peaceful use of nuclear medicine"),
        .init(
            "Mutis", fullName: "José Celestino Mutis", field: "Biology", years: "1732–1808",
            region: .latinAmerica, gender: .man,
            note: "Led the botanical survey of New Granada"),
        .init(
            "Nagaoka", fullName: "Hantaro Nagaoka", field: "Physics", years: "1865–1950",
            region: .eastAsia, gender: .man,
            note: "Proposed the Saturnian model of the atom"),
        .init(
            "Nambu", fullName: "Yoichiro Nambu", field: "Physics", years: "1921–2015",
            region: .eastAsia, gender: .man,
            note: "Spontaneous symmetry breaking"),
        .init(
            "Nash", fullName: "John Forbes Nash Jr.", field: "Mathematics", years: "1928–2015",
            region: .northAmerica, gender: .man,
            note: "Game theory; the Nash equilibrium"),
        .init(
            "Negishi", fullName: "Ei-ichi Negishi", field: "Chemistry", years: "1935–2021",
            region: .eastAsia, gender: .man,
            note: "Negishi coupling"),
        .init(
            "Neumann", fullName: "John von Neumann and Klára Dán von Neumann", field: "Mathematics", years: "1903–1963",
            region: .europe, gender: .both,
            note: "Game theory (John); wrote the first modern-style program for ENIAC (Klára)"),
        .init(
            "Newton", fullName: "Isaac Newton and Margaret Newton", field: "Physics", years: "1643–1971",
            region: .europe, gender: .both,
            note: "Laws of motion and gravitation (Isaac); wheat rust research in Canada (Margaret)"),
        .init(
            "Nightingale", fullName: "Florence Nightingale", field: "Medicine", years: "1820–1910",
            region: .europe, gender: .woman,
            note: "Founded modern nursing; pioneer of statistical graphics"),
        .init(
            "Nishina", fullName: "Yoshio Nishina", field: "Physics", years: "1890–1951",
            region: .eastAsia, gender: .man,
            note: "Founded modern physics research in Japan"),
        .init(
            "Noddack", fullName: "Ida Noddack", field: "Physics", years: "1896–1978",
            region: .europe, gender: .woman,
            note: "Co-found rhenium; first proposed nuclear fission"),
        .init(
            "Noether", fullName: "Emmy Noether", field: "Mathematics", years: "1882–1935",
            region: .europe, gender: .woman,
            note: "Abstract algebra; symmetry and conservation laws"),
        .init(
            "Nyokong", fullName: "Tebello Nyokong", field: "Chemistry", years: "born 1951", isLiving: true,
            region: .africa, gender: .woman,
            note: "South African chemist; light-activated cancer drugs; L'Oréal-UNESCO Award"),
        .init(
            "Nüsslein-Volhard", fullName: "Christiane Nüsslein-Volhard", field: "Biology", years: "born 1942",
            isLiving: true,
            region: .europe, gender: .woman,
            note: "Genes that control early development; Nobel Prize"),
        .init(
            "Ochoa", fullName: "Severo Ochoa", field: "Biology", years: "1905–1993",
            region: .europe, gender: .man,
            note: "Synthesis of RNA"),
        .init(
            "Odhiambo", fullName: "Thomas Risley Odhiambo", field: "Biology", years: "1931–2003",
            region: .africa, gender: .man,
            note: "Kenyan entomologist; founded the ICIPE research centre"),
        .init(
            "Ogino", fullName: "Ogino Ginko", field: "Medicine", years: "1851–1913",
            region: .eastAsia, gender: .woman,
            note: "Japan's first licensed woman physician in Western medicine"),
        .init(
            "Ohm", fullName: "Georg Ohm", field: "Physics", years: "1789–1854",
            region: .europe, gender: .man,
            note: "Law relating voltage, current and resistance"),
        .init(
            "Ohno", fullName: "Susumu Ohno", field: "Biology", years: "1928–2000",
            region: .eastAsia, gender: .man,
            note: "Evolution by gene duplication"),
        .init(
            "Ohsumi", fullName: "Yoshinori Ohsumi", field: "Biology", years: "born 1945", isLiving: true,
            region: .eastAsia, gender: .man,
            note: "How cells recycle their parts (autophagy); Nobel Prize"),
        .init(
            "Oka", fullName: "Kiyoshi Oka", field: "Mathematics", years: "1901–1978",
            region: .eastAsia, gender: .man,
            note: "Functions of several complex variables"),
        .init(
            "Okazaki", fullName: "Reiji Okazaki", field: "Biology", years: "1930–1975",
            region: .eastAsia, gender: .man,
            note: "Found the Okazaki fragments of DNA replication"),
        .init(
            "Okeke", fullName: "Francisca Nneka Okeke", field: "Physics", years: "born 1956", isLiving: true,
            region: .africa, gender: .woman,
            note: "Nigerian physicist; the ionosphere; L'Oréal-UNESCO Award"),
        .init(
            "Oleinik", fullName: "Olga Oleinik", field: "Mathematics", years: "1925–2001",
            region: .europe, gender: .woman,
            note: "Partial differential equations"),
        .init(
            "Oliphant", fullName: "Mark Oliphant", field: "Physics", years: "1901–2000",
            region: .oceania, gender: .man,
            note: "Australian; nuclear fusion of hydrogen isotopes"),
        .init(
            "Pascal", fullName: "Blaise Pascal", field: "Mathematics", years: "1623–1662",
            region: .europe, gender: .man,
            note: "Probability; Pascal's triangle; a mechanical calculator"),
        .init(
            "Pasteur", fullName: "Louis Pasteur", field: "Biology", years: "1822–1895",
            region: .europe, gender: .man,
            note: "Germ theory; pasteurization; rabies vaccine"),
        .init(
            "Patapoutian", fullName: "Ardem Patapoutian", field: "Biology", years: "born 1967", isLiving: true,
            region: .westAndCentralAsia, gender: .man,
            note: "Lebanese-born; sensors for touch and temperature; Nobel Prize"),
        .init(
            "Patricia Bath", fullName: "Patricia Bath", field: "Medicine", years: "1942–2019",
            region: .northAmerica, gender: .woman,
            note: "Invented a laser method to remove cataracts"),
        .init(
            "Pauli", fullName: "Wolfgang Pauli", field: "Physics", years: "1900–1958",
            region: .europe, gender: .man,
            note: "Exclusion principle; predicted the neutrino"),
        .init(
            "Pavlov", fullName: "Ivan Pavlov", field: "Biology", years: "1849–1936",
            region: .europe, gender: .man,
            note: "Classical conditioning; physiology of digestion"),
        .init(
            "Payne-Gaposchkin", fullName: "Cecilia Payne-Gaposchkin", field: "Astronomy", years: "1900–1979",
            region: .northAmerica, gender: .woman,
            note: "Showed that stars are made mostly of hydrogen and helium"),
        .init(
            "Payne-Scott", fullName: "Ruby Payne-Scott", field: "Astronomy", years: "1912–1981",
            region: .oceania, gender: .woman,
            note: "Australian pioneer of radio astronomy and solar radio bursts"),
        .init(
            "Penfield", fullName: "Wilder Penfield", field: "Medicine", years: "1891–1976",
            region: .northAmerica, gender: .man,
            note: "Canadian; mapped the brain during surgery"),
        .init(
            "Pennington", fullName: "Mary Engle Pennington", field: "Chemistry", years: "1872–1952",
            region: .northAmerica, gender: .woman,
            note: "Food safety and refrigeration"),
        .init(
            "Percy Julian", fullName: "Percy Lavon Julian", field: "Chemistry", years: "1899–1975",
            region: .northAmerica, gender: .man,
            note: "Made medicines from plant chemicals, including cortisone"),
        .init(
            "Perey", fullName: "Marguerite Perey", field: "Chemistry", years: "1909–1975",
            region: .europe, gender: .woman,
            note: "Found francium"),
        .init(
            "Piailug", fullName: "Mau Piailug", field: "Earth science", years: "1932–2010",
            region: .oceania, gender: .man,
            note: "Micronesian master navigator; revived traditional wayfinding"),
        .init(
            "Picotte", fullName: "Susan La Flesche Picotte", field: "Medicine", years: "1865–1915",
            region: .northAmerica, gender: .woman,
            note: "Omaha physician; first Native American woman to earn an MD"),
        .init(
            "Planck", fullName: "Max Planck", field: "Physics", years: "1858–1947",
            region: .europe, gender: .man,
            note: "Founded quantum theory"),
        .init(
            "Plaskett", fullName: "John Stanley Plaskett", field: "Astronomy", years: "1865–1941",
            region: .northAmerica, gender: .man,
            note: "Canadian; measured the rotation of the Milky Way"),
        .init(
            "Poincaré", fullName: "Henri Poincaré", field: "Mathematics", years: "1854–1912",
            region: .europe, gender: .man,
            note: "Topology; chaos in the three-body problem"),
        .init(
            "Ponnamperuma", fullName: "Cyril Ponnamperuma", field: "Chemistry", years: "1923–1994",
            region: .southAsia, gender: .man,
            note: "Sri Lankan; chemistry of the origin of life"),
        .init(
            "Ptolemy", fullName: "Claudius Ptolemy", field: "Astronomy", years: "c. 100–c. 170",
            region: .africa, gender: .man,
            note: "Wrote the Almagest, the standard astronomy text for 1,400 years"),
        .init(
            "Pythagoras", fullName: "Pythagoras of Samos", field: "Mathematics", years: "c. 570–c. 495 BCE",
            region: .europe, gender: .man,
            note: "The theorem on right triangles; numbers and music"),
        .init(
            "Pōmare", fullName: "Māui Pōmare", field: "Medicine", years: "1875–1930",
            region: .oceania, gender: .man,
            note: "First Māori medical doctor; public health for Māori communities"),
        .init(
            "Quarterman", fullName: "Lloyd Quarterman", field: "Chemistry", years: "1918–1982",
            region: .northAmerica, gender: .man,
            note: "Chemist on the Manhattan Project; fluorine chemistry"),
        .init(
            "Qudrat-i-Khuda", fullName: "Muhammad Qudrat-i-Khuda", field: "Chemistry", years: "1900–1977",
            region: .southAsia, gender: .man,
            note: "Bangladeshi chemist; founded research laboratories in Dhaka"),
        .init(
            "Ramachandran", fullName: "G. N. Ramachandran", field: "Biology", years: "1922–2001",
            region: .southAsia, gender: .man,
            note: "The Ramachandran plot of protein structure"),
        .init(
            "Ramakrishnan", fullName: "Venki Ramakrishnan", field: "Biology", years: "born 1952", isLiving: true,
            region: .southAsia, gender: .man,
            note: "Structure of the ribosome; Nobel Prize"),
        .init(
            "Raman", fullName: "C. V. Raman", field: "Physics", years: "1888–1970",
            region: .southAsia, gender: .man,
            note: "Found the Raman scattering of light"),
        .init(
            "Ramanujan", fullName: "Srinivasa Ramanujan", field: "Mathematics", years: "1887–1920",
            region: .southAsia, gender: .man,
            note: "Self-taught; thousands of results on series and partitions"),
        .init(
            "Ranadive", fullName: "Kamal Ranadive", field: "Medicine", years: "1917–2001",
            region: .southAsia, gender: .woman,
            note: "Indian cancer researcher; founded the Indian Women Scientists' Association"),
        .init(
            "Ranganathan", fullName: "Darshan Ranganathan", field: "Chemistry", years: "1941–2001",
            region: .southAsia, gender: .woman,
            note: "Indian organic chemist; designed molecules that mimic proteins"),
        .init(
            "Rao", fullName: "C. R. Rao", field: "Statistics", years: "1920–2023",
            region: .southAsia, gender: .man,
            note: "Cramér–Rao bound; Rao–Blackwell theorem"),
        .init(
            "Riemann", fullName: "Bernhard Riemann", field: "Mathematics", years: "1826–1866",
            region: .europe, gender: .man,
            note: "Riemann geometry; the Riemann hypothesis"),
        .init(
            "Rillieux", fullName: "Norbert Rillieux", field: "Engineering", years: "1806–1894",
            region: .northAmerica, gender: .man,
            note: "Invented the multiple-effect evaporator for refining sugar"),
        .init(
            "Ritchie", fullName: "Dennis Ritchie", field: "Computing", years: "1941–2011",
            region: .northAmerica, gender: .man,
            note: "The C language; co-created Unix"),
        .init(
            "Roebling", fullName: "Emily Warren Roebling", field: "Engineering", years: "1843–1903",
            region: .northAmerica, gender: .woman,
            note: "Led the completion of the Brooklyn Bridge"),
        .init(
            "Ross", fullName: "Mary Golda Ross", field: "Engineering", years: "1908–2008",
            region: .northAmerica, gender: .woman,
            note: "Cherokee; first Native American woman engineer; spacecraft design"),
        .init(
            "Rubin", fullName: "Vera Rubin", field: "Astronomy", years: "1928–2016",
            region: .northAmerica, gender: .woman,
            note: "Evidence for dark matter from galaxy rotation"),
        .init(
            "Rudin", fullName: "Mary Ellen Rudin", field: "Mathematics", years: "1924–2013",
            region: .northAmerica, gender: .woman,
            note: "Set-theoretic topology"),
        .init(
            "Ruth Arnon", fullName: "Ruth Arnon", field: "Biology", years: "born 1933", isLiving: true,
            region: .westAndCentralAsia, gender: .woman,
            note: "Co-developed a drug for multiple sclerosis; Israel Prize"),
        .init(
            "Rutherford", fullName: "Ernest Rutherford", field: "Physics", years: "1871–1937",
            region: .oceania, gender: .man,
            note: "New Zealander; found the atomic nucleus"),
        .init(
            "Röntgen", fullName: "Wilhelm Röntgen", field: "Physics", years: "1845–1923",
            region: .europe, gender: .man,
            note: "Found X-rays"),
        .init(
            "Sagan", fullName: "Carl Sagan", field: "Astronomy", years: "1934–1996",
            region: .northAmerica, gender: .man,
            note: "Planetary science; taught astronomy to the public"),
        .init(
            "Sager", fullName: "Ruth Sager", field: "Biology", years: "1918–1997",
            region: .northAmerica, gender: .woman,
            note: "Found genes outside the cell nucleus"),
        .init(
            "Saha", fullName: "Meghnad Saha", field: "Astronomy", years: "1893–1956",
            region: .southAsia, gender: .man,
            note: "Ionization equation used to read the spectra of stars"),
        .init(
            "Sahni", fullName: "Birbal Sahni", field: "Earth science", years: "1891–1949",
            region: .southAsia, gender: .man,
            note: "Founded palaeobotany in India"),
        .init(
            "Sakata", fullName: "Shoichi Sakata", field: "Physics", years: "1911–1970",
            region: .eastAsia, gender: .man,
            note: "The Sakata model of hadrons"),
        .init(
            "Sakharov", fullName: "Andrei Sakharov", field: "Physics", years: "1921–1989",
            region: .europe, gender: .man,
            note: "Physicist and human-rights campaigner; Nobel Peace Prize"),
        .init(
            "Salam", fullName: "Abdus Salam", field: "Physics", years: "1926–1996",
            region: .southAsia, gender: .man,
            note: "Electroweak unification; Pakistan's first Nobel laureate in science"),
        .init(
            "Sammet", fullName: "Jean E. Sammet", field: "Computing", years: "1928–2017",
            region: .northAmerica, gender: .woman,
            note: "COBOL; history of programming languages"),
        .init(
            "Sancar", fullName: "Aziz Sancar", field: "Chemistry", years: "born 1946", isLiving: true,
            region: .westAndCentralAsia, gender: .man,
            note: "How cells repair DNA; Nobel Prize"),
        .init(
            "Santos-Dumont", fullName: "Alberto Santos-Dumont", field: "Engineering", years: "1873–1932",
            region: .latinAmerica, gender: .man,
            note: "Brazilian pioneer of airships and aircraft"),
        .init(
            "Sarabhai", fullName: "Vikram Sarabhai", field: "Physics", years: "1919–1971",
            region: .southAsia, gender: .man,
            note: "Founded India's space program"),
        .init(
            "Saruhashi", fullName: "Katsuko Saruhashi", field: "Earth science", years: "1920–2007",
            region: .eastAsia, gender: .woman,
            note: "Japanese geochemist; measured carbon dioxide and fallout in seawater"),
        .init(
            "Saylan", fullName: "Türkan Saylan", field: "Medicine", years: "1935–2009",
            region: .westAndCentralAsia, gender: .woman,
            note: "Turkish physician; fought leprosy"),
        .init(
            "Schenberg", fullName: "Mário Schenberg", field: "Physics", years: "1914–1990",
            region: .latinAmerica, gender: .man,
            note: "Brazilian; the Urca process in supernovae"),
        .init(
            "Schiemann", fullName: "Elisabeth Schiemann", field: "Biology", years: "1881–1972",
            region: .europe, gender: .woman,
            note: "History of crop plants; plant genetics"),
        .init(
            "Schrödinger", fullName: "Erwin Schrödinger", field: "Physics", years: "1887–1961",
            region: .europe, gender: .man,
            note: "Wave equation of quantum mechanics"),
        .init(
            "Seacole", fullName: "Mary Seacole", field: "Medicine", years: "1805–1881",
            region: .latinAmerica, gender: .woman,
            note: "Jamaican nurse; treated soldiers in the Crimean War"),
        .init(
            "Seki", fullName: "Seki Takakazu", field: "Mathematics", years: "1642–1708",
            region: .eastAsia, gender: .man,
            note: "Found determinants before Leibniz"),
        .init(
            "Semmelweis", fullName: "Ignaz Semmelweis", field: "Medicine", years: "1818–1865",
            region: .europe, gender: .man,
            note: "Showed that handwashing prevents infection"),
        .init(
            "Shannon", fullName: "Claude Shannon", field: "Computing", years: "1916–2001",
            region: .northAmerica, gender: .man,
            note: "Founded information theory"),
        .init(
            "Shen Kuo", fullName: "Shen Kuo", field: "Earth science", years: "1031–1095",
            region: .eastAsia, gender: .man,
            note: "Described the magnetic compass and how landforms erode"),
        .init(
            "Shiga", fullName: "Kiyoshi Shiga", field: "Biology", years: "1871–1957",
            region: .eastAsia, gender: .man,
            note: "Found the dysentery bacillus, Shigella"),
        .init(
            "Shilling", fullName: "Beatrice Shilling", field: "Engineering", years: "1909–1990",
            region: .europe, gender: .woman,
            note: "Fixed a fuel-flow fault in fighter aircraft engines"),
        .init(
            "Shima", fullName: "Hideo Shima", field: "Engineering", years: "1901–1998",
            region: .eastAsia, gender: .man,
            note: "Chief engineer of the Shinkansen bullet train"),
        .init(
            "Shimomura", fullName: "Osamu Shimomura", field: "Biology", years: "1928–2018",
            region: .eastAsia, gender: .man,
            note: "Found green fluorescent protein"),
        .init(
            "Silveira", fullName: "Nise da Silveira", field: "Medicine", years: "1905–1999",
            region: .latinAmerica, gender: .woman,
            note: "Brazilian psychiatrist; used art therapy instead of harsh treatments"),
        .init(
            "Sinha", fullName: "Purnima Sinha", field: "Physics", years: "1927–2015",
            region: .southAsia, gender: .woman,
            note: "Indian physicist; X-ray crystallography of clays and biological molecules"),
        .init(
            "Sohonie", fullName: "Kamala Sohonie", field: "Chemistry", years: "1911–1998",
            region: .southAsia, gender: .woman,
            note: "Indian biochemist; first Indian woman to earn a PhD in science"),
        .init(
            "Somerville", fullName: "Mary Somerville", field: "Astronomy", years: "1780–1872",
            region: .europe, gender: .woman,
            note: "Explained celestial mechanics; predicted a planet beyond Uranus"),
        .init(
            "Spence", fullName: "Frances Spence", field: "Computing", years: "1922–2012",
            region: .northAmerica, gender: .woman,
            note: "ENIAC programmer"),
        .init(
            "Spärck Jones", fullName: "Karen Spärck Jones", field: "Computing", years: "1935–2007",
            region: .europe, gender: .woman,
            note: "Inverse document frequency, the basis of search engines"),
        .init(
            "Stevens", fullName: "Nettie Stevens", field: "Biology", years: "1861–1912",
            region: .northAmerica, gender: .woman,
            note: "Found that chromosomes determine sex"),
        .init(
            "Stowe", fullName: "Emily Stowe", field: "Medicine", years: "1831–1903",
            region: .northAmerica, gender: .woman,
            note: "One of Canada's first women physicians"),
        .init(
            "Strickland", fullName: "Donna Strickland", field: "Physics", years: "born 1959", isLiving: true,
            region: .northAmerica, gender: .woman,
            note: "Canadian; chirped pulse amplification of lasers; Nobel Prize; University of Waterloo"),
        .init(
            "Subbarow", fullName: "Yellapragada Subbarow", field: "Medicine", years: "1895–1948",
            region: .southAsia, gender: .man,
            note: "Made methotrexate; found the role of ATP in muscle"),
        .init(
            "Sudarshan", fullName: "E. C. George Sudarshan", field: "Physics", years: "1931–2018",
            region: .southAsia, gender: .man,
            note: "Quantum optics; the V-A theory of weak interactions"),
        .init(
            "Sushruta", fullName: "Sushruta", field: "Medicine", years: "c. 600–c. 500 BCE",
            region: .southAsia, gender: .man,
            note: "Early text on surgery, including reconstructive surgery"),
        .init(
            "Swaminathan", fullName: "M. S. Swaminathan", field: "Biology", years: "1925–2023",
            region: .southAsia, gender: .man,
            note: "Plant geneticist; led India's green revolution"),
        .init(
            "Takagi", fullName: "Teiji Takagi", field: "Mathematics", years: "1875–1960",
            region: .eastAsia, gender: .man,
            note: "Class field theory"),
        .init(
            "Takamine", fullName: "Jōkichi Takamine", field: "Chemistry", years: "1854–1922",
            region: .eastAsia, gender: .man,
            note: "Isolated adrenaline"),
        .init(
            "Tan Yunxian", fullName: "Tan Yunxian", field: "Medicine", years: "1461–1556",
            region: .eastAsia, gender: .woman,
            note: "Chinese physician; wrote a book of her own case records"),
        .init(
            "Taussig", fullName: "Helen Taussig", field: "Medicine", years: "1898–1986",
            region: .northAmerica, gender: .woman,
            note: "Founded paediatric cardiology"),
        .init(
            "Taussky-Todd", fullName: "Olga Taussky-Todd", field: "Mathematics", years: "1906–1995",
            region: .europe, gender: .woman,
            note: "Matrix theory and number theory"),
        .init(
            "Teitelbaum", fullName: "Ruth Teitelbaum", field: "Computing", years: "1924–1986",
            region: .northAmerica, gender: .woman,
            note: "ENIAC programmer"),
        .init(
            "Tesla", fullName: "Nikola Tesla", field: "Engineering", years: "1856–1943",
            region: .europe, gender: .man,
            note: "Alternating-current motors and power systems"),
        .init(
            "Tharp", fullName: "Marie Tharp", field: "Earth science", years: "1920–2006",
            region: .northAmerica, gender: .woman,
            note: "First map of the ocean floor; the mid-Atlantic rift"),
        .init(
            "Theiler", fullName: "Max Theiler", field: "Medicine", years: "1899–1972",
            region: .africa, gender: .man,
            note: "South African; vaccine for yellow fever"),
        .init(
            "Tinsley", fullName: "Beatrice Tinsley", field: "Astronomy", years: "1941–1981",
            region: .oceania, gender: .woman,
            note: "New Zealander; showed how galaxies change as their stars age"),
        .init(
            "Tomonaga", fullName: "Sin-Itiro Tomonaga", field: "Physics", years: "1906–1979",
            region: .eastAsia, gender: .man,
            note: "Quantum electrodynamics"),
        .init(
            "Tu Youyou", fullName: "Tu Youyou", field: "Medicine", years: "born 1930", isLiving: true,
            region: .eastAsia, gender: .woman,
            note: "Found artemisinin for malaria; Nobel Prize"),
        .init(
            "Tukey", fullName: "John Tukey", field: "Statistics", years: "1915–2000",
            region: .northAmerica, gender: .man,
            note: "Exploratory data analysis; the fast Fourier transform; named the bit"),
        .init(
            "Tupaia", fullName: "Tupaia", field: "Earth science", years: "c. 1725–1770",
            region: .oceania, gender: .man,
            note: "Tahitian navigator; mapped the Pacific islands for James Cook"),
        .init(
            "Turing", fullName: "Alan Turing", field: "Computing", years: "1912–1954",
            region: .europe, gender: .man,
            note: "Theory of computation; broke Enigma"),
        .init(
            "Tutte", fullName: "W. T. Tutte", field: "Mathematics", years: "1917–2002",
            region: .northAmerica, gender: .man,
            note: "Broke the Lorenz cipher; graph theory at the University of Waterloo"),
        .init(
            "Tyndall", fullName: "John Tyndall", field: "Earth science", years: "1820–1893",
            region: .europe, gender: .man,
            note: "Measured how gases absorb heat; the greenhouse effect"),
        .init(
            "Uchida", fullName: "Irene Uchida", field: "Biology", years: "1917–2013",
            region: .northAmerica, gender: .woman,
            note: "Japanese Canadian geneticist; chromosome studies of Down syndrome"),
        .init(
            "Uhlenbeck", fullName: "Karen Uhlenbeck", field: "Mathematics", years: "born 1942", isLiving: true,
            region: .northAmerica, gender: .woman,
            note: "Geometric analysis; Abel Prize"),
        .init(
            "Ulugh Beg", fullName: "Ulugh Beg", field: "Astronomy", years: "1394–1449",
            region: .westAndCentralAsia, gender: .man,
            note: "Built the Samarkand observatory; a star catalogue of 1,018 stars"),
        .init(
            "Vaughan", fullName: "Dorothy Vaughan", field: "Computing", years: "1910–2008",
            region: .northAmerica, gender: .woman,
            note: "Led NASA's West Area Computing unit; taught FORTRAN"),
        .init(
            "Venkatesh", fullName: "Akshay Venkatesh", field: "Mathematics", years: "born 1981", isLiving: true,
            region: .southAsia, gender: .man,
            note: "Number theory; Fields Medal"),
        .init(
            "Venn", fullName: "John Venn", field: "Mathematics", years: "1834–1923",
            region: .europe, gender: .man,
            note: "Venn diagrams"),
        .init(
            "Vesalius", fullName: "Andreas Vesalius", field: "Medicine", years: "1514–1564",
            region: .europe, gender: .man,
            note: "Founded modern human anatomy"),
        .init(
            "Viazovska", fullName: "Maryna Viazovska", field: "Mathematics", years: "born 1984", isLiving: true,
            region: .europe, gender: .woman,
            note: "Ukrainian; sphere packing in 8 and 24 dimensions; Fields Medal"),
        .init(
            "Visvesvaraya", fullName: "M. Visvesvaraya", field: "Engineering", years: "1861–1962",
            region: .southAsia, gender: .man,
            note: "Dams, flood control and irrigation in India"),
        .init(
            "Vogt", fullName: "Marthe Vogt", field: "Biology", years: "1903–2003",
            region: .europe, gender: .woman,
            note: "Role of noradrenaline as a neurotransmitter"),
        .init(
            "Volta", fullName: "Alessandro Volta", field: "Physics", years: "1745–1827",
            region: .europe, gender: .man,
            note: "Made the first electric battery, the voltaic pile"),
        .init(
            "Wang Zhenyi", fullName: "Wang Zhenyi", field: "Astronomy", years: "1768–1797",
            region: .eastAsia, gender: .woman,
            note: "Explained lunar eclipses with a model; wrote on mathematics"),
        .init(
            "Watt", fullName: "James Watt", field: "Engineering", years: "1736–1819",
            region: .europe, gender: .man,
            note: "Improved the steam engine"),
        .init(
            "Wegener", fullName: "Alfred Wegener", field: "Earth science", years: "1880–1930",
            region: .europe, gender: .man,
            note: "Continental drift"),
        .init(
            "Wirth", fullName: "Niklaus Wirth", field: "Computing", years: "1934–2024",
            region: .europe, gender: .man,
            note: "Pascal and Modula-2"),
        .init(
            "Wong-Staal", fullName: "Flossie Wong-Staal", field: "Biology", years: "1946–2020",
            region: .eastAsia, gender: .woman,
            note: "Chinese American virologist; first to clone HIV"),
        .init(
            "Worsley", fullName: "Beatrice Worsley", field: "Computing", years: "1921–1972",
            region: .northAmerica, gender: .woman,
            note: "Canadian; wrote early compilers in Toronto"),
        .init(
            "Yaghi", fullName: "Omar Yaghi", field: "Chemistry", years: "born 1965", isLiving: true,
            region: .westAndCentralAsia, gender: .man,
            note: "Jordanian American; metal-organic frameworks; Wolf Prize"),
        .init(
            "Yagi", fullName: "Hidetsugu Yagi", field: "Engineering", years: "1886–1976",
            region: .eastAsia, gender: .man,
            note: "The Yagi–Uda antenna"),
        .init(
            "Yalow", fullName: "Rosalyn Yalow", field: "Medicine", years: "1921–2011",
            region: .northAmerica, gender: .woman,
            note: "Radioimmunoassay"),
        .init(
            "Yamanaka", fullName: "Shinya Yamanaka", field: "Medicine", years: "born 1962", isLiving: true,
            region: .eastAsia, gender: .man,
            note: "Reprogrammed adult cells into stem cells; Nobel Prize"),
        .init(
            "Yasui", fullName: "Kono Yasui", field: "Biology", years: "1880–1971",
            region: .eastAsia, gender: .woman,
            note: "First Japanese woman to earn a doctorate; plant cytology"),
        .init(
            "Yau", fullName: "Shing-Tung Yau", field: "Mathematics", years: "born 1949", isLiving: true,
            region: .eastAsia, gender: .man,
            note: "Calabi–Yau manifolds; Fields Medal"),
        .init(
            "Yermolyeva", fullName: "Zinaida Yermolyeva", field: "Medicine", years: "1898–1974",
            region: .europe, gender: .woman,
            note: "Made the first Soviet penicillin"),
        .init(
            "Yoshino", fullName: "Akira Yoshino", field: "Chemistry", years: "born 1948", isLiving: true,
            region: .eastAsia, gender: .man,
            note: "Made the first practical lithium-ion battery; Nobel Prize"),
        .init(
            "Yuasa", fullName: "Toshiko Yuasa", field: "Physics", years: "1909–1980",
            region: .eastAsia, gender: .woman,
            note: "Japan's first woman physicist; nuclear and beta-ray spectroscopy"),
        .init(
            "Yukawa", fullName: "Hideki Yukawa", field: "Physics", years: "1907–1981",
            region: .eastAsia, gender: .man,
            note: "Predicted the meson; Japan's first Nobel laureate"),
        .init(
            "Zadeh", fullName: "Lotfi Zadeh", field: "Computing", years: "1921–2017",
            region: .westAndCentralAsia, gender: .man,
            note: "Fuzzy logic and fuzzy sets"),
        .init(
            "Zewail", fullName: "Ahmed Zewail", field: "Chemistry", years: "1946–2016",
            region: .africa, gender: .man,
            note: "Femtochemistry; filmed chemical reactions"),
        .init(
            "Zhang Heng", fullName: "Zhang Heng", field: "Astronomy", years: "78–139",
            region: .eastAsia, gender: .man,
            note: "Built the first seismoscope and a water-powered armillary sphere"),
        .init(
            "Zoghbi", fullName: "Huda Zoghbi", field: "Medicine", years: "born 1954", isLiving: true,
            region: .westAndCentralAsia, gender: .woman,
            note: "Lebanese American; the gene for Rett syndrome; Breakthrough Prize"),
        .init(
            "Zu Chongzhi", fullName: "Zu Chongzhi", field: "Mathematics", years: "429–500",
            region: .eastAsia, gender: .man,
            note: "Calculated pi to seven digits"),
        .init(
            "Ōmura", fullName: "Satoshi Ōmura", field: "Biology", years: "born 1935", isLiving: true,
            region: .eastAsia, gender: .man,
            note: "Found avermectin, against river blindness; Nobel Prize"),
    ]

    /// Removed in the Fall 2026 review so that the list could hold more women
    /// and more people from outside Europe and North America. Each is a good
    /// choice on its own. AvatarHandleTests asserts that none is back on the
    /// list; add one only with a balance review.
    public static let removedForBalance: [String] = [
        "Aristarchus", "Atanasoff", "Banach", "Baran", "Bardeen", "Becquerel", "Behring", "Bernoulli", "Berzelius",
        "Bethe", "Bjerknes", "Brunel", "Butlerov", "Carnot", "Cauchy", "Cavendish", "Cayley", "Chadwick",
        "Chargaff", "Chebyshev", "Cherenkov", "Collip", "Compton", "Coriolis", "Coulomb", "Dedekind", "Dirichlet",
        "Eckert", "Eddington", "Ehrlich", "Fields", "Fizeau", "Foucault", "Fraunhofer", "Fresnel", "Gamow", "Gibbs",
        "Ginzburg", "Goddard", "Golgi", "Gosset", "Grignard", "Grothendieck", "Hevesy", "Hollerith", "Hooke",
        "Hoyle", "Hutton", "Huygens", "Jacobi", "Jansky", "Kapitsa", "Kekulé", "Kemeny", "Kilby", "Kildall",
        "Kirchhoff", "Korolev", "Krebs", "Kármán", "Lagrange", "Lamarck", "Landau", "Langmuir", "Laue", "Licklider",
        "Liebig", "Littlewood", "Lobachevsky", "Lomonosov", "Lorentz", "Lyapunov", "Mach", "Mauchly", "Michelson",
        "Minkowski", "Moseley", "Napier", "Navier", "Nernst", "Neyman", "Noyce", "Nyquist", "Postel", "Prelog",
        "Priestley", "Quetelet", "Rabi", "Ramsay", "Rayleigh", "Revelle", "Richter", "Rossby", "Sabatier",
        "Scheele", "Segrè", "Sherrington", "Sommerfeld", "Szilárd", "Telford", "Thurston", "Tsiolkovsky", "Wald",
        "Weierstrass", "Wigner", "Wilkes", "Woodward", "Wöhler", "Zeeman",
    ]
}
