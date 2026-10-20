### Security

- **A test setup or draft from another course is refused (#2742).** Quick publish (`POST /instructor`) now refuses a setup that is not in the active course. The new-assignment form (`GET /instructor/new?draftID=`), its draft solution notebook and its save (`POST /instructor/new/save`) now check the draft's own course, as the other draft routes do. Before, an instructor of one course could publish another course's setup, read another course's draft and its solution, or move that draft into their own course.
