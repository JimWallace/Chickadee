### Security

- **The notebook source route checks `submissionID`.** The route now accepts
  only the ID of a submission of this assignment that the caller may open, as
  the notebook page already did. Before, an unchecked ID went into a file path
  and could reach a file outside the caller's folder.
