# Changelog

## 0.1.0 (2026-11-17)


### Features

* add plugin manifest and marketplace ([21e328a](https://github.com/Sycatle/senior-mode/commit/21e328ab12b56dc7dc7becd72094062456fede55))
* **agents:** add the specialised team ([d7c87f7](https://github.com/Sycatle/senior-mode/commit/d7c87f78aff76a12127e9d07cef2f69ac9760427))
* **bin:** create a ticket with its board fields and links in one call ([7a5fb5c](https://github.com/Sycatle/senior-mode/commit/7a5fb5ce8bc177fd69220facaaf99c50cec722a5))
* **bin:** publish releases with release-please from the terminal ([f608370](https://github.com/Sycatle/senior-mode/commit/f60837007a9c51e2a863d64642c2270bfbc8c3a9)), refs [#18](https://github.com/Sycatle/senior-mode/issues/18)
* **bin:** read the project config and set Project fields ([11a31fc](https://github.com/Sycatle/senior-mode/commit/11a31fc67e1e3a99e590d43e88b4f659fcd15ad3))
* **bin:** run checks locally and publish them as a commit status ([b83ca08](https://github.com/Sycatle/senior-mode/commit/b83ca08684eae93fb49a7ad35b187c794bc047ef))
* **bin:** set up a repository's documents and checks ([84aa986](https://github.com/Sycatle/senior-mode/commit/84aa986cd2fe27bd27bb5fc0b248da993316e359))
* **bin:** set up the GitHub side of a project ([8876a7c](https://github.com/Sycatle/senior-mode/commit/8876a7c5c56a197eac00aa642ec412451aeac282))
* **frame:** turn an idea into a spec, ADRs and tickets ([20d1d73](https://github.com/Sycatle/senior-mode/commit/20d1d73c383db8c6f10d7f11fe91fdc411763575)), refs [#14](https://github.com/Sycatle/senior-mode/issues/14)
* **hooks:** deny git commands that skip checks or rewrite shared history ([f5ab777](https://github.com/Sycatle/senior-mode/commit/f5ab777e24f551b4d614c90741bfe3473a3b1324))
* **hooks:** refuse to finish with unverified edits ([def5f91](https://github.com/Sycatle/senior-mode/commit/def5f91830632b67d7ceb8ec7ddf3cb683dd2a7d))
* **hooks:** start each session with the current ticket ([97e6bbd](https://github.com/Sycatle/senior-mode/commit/97e6bbdd759098cc8d9c31900efdc16ad5f36d57))
* **presets:** set up TypeScript projects from their own scripts ([4655012](https://github.com/Sycatle/senior-mode/commit/4655012b9dd2845620b2f5211a497f18770d4275))
* **setup:** name the package.json preset node and report its language ([76633ff](https://github.com/Sycatle/senior-mode/commit/76633ffd36641bb7a8bae240a3fdf302def6513f)), refs [#42](https://github.com/Sycatle/senior-mode/issues/42)
* **skills:** add the delivery disciplines ([71195a4](https://github.com/Sycatle/senior-mode/commit/71195a43b37c37348ad373850cb392c649542a2d))
* **skills:** add the planning disciplines ([80da887](https://github.com/Sycatle/senior-mode/commit/80da887ba74c6ecb4c76584dd9e61ef856c93a95))
* **skills:** add the setup command ([ff1ebff](https://github.com/Sycatle/senior-mode/commit/ff1ebffcb9dbf4aecc1a28eb57e1aa2bb70e2c0a))


### Bug Fixes

* **bin:** close the gaps left in setup repo after review ([c6dbd0b](https://github.com/Sycatle/senior-mode/commit/c6dbd0baf8c4c5ab7be328bc8b8fc3e37722769f))
* **bin:** keep a reused ticket's status and set its fields at once ([bc0ecc1](https://github.com/Sycatle/senior-mode/commit/bc0ecc135216a5e2da5bb94dd86ef7be3af64c9d))
* **bin:** keep setup repo from losing user content or passing bad commits ([6055da4](https://github.com/Sycatle/senior-mode/commit/6055da40a81ac005eed4df97134eb44a75afced1))
* **bin:** let the first push reach an empty origin ([78f142a](https://github.com/Sycatle/senior-mode/commit/78f142a4a168fd5aed4fe26b5bd0271961090c45))
* **bin:** make setup github safe on existing repositories ([dd1a383](https://github.com/Sycatle/senior-mode/commit/dd1a3830400571adbcdfdfec10d6c1faefcabd1f))
* **bin:** pass reused tickets' label names whole ([cd609e9](https://github.com/Sycatle/senior-mode/commit/cd609e9996be3eeceb8c2b14bc256451d7f43145))
* **bin:** remove the release token file when the run is interrupted ([6dd0de7](https://github.com/Sycatle/senior-mode/commit/6dd0de72fae59b5b3c9c6023942e95f40f57b46f))
* **bin:** retry GitHub calls that fail transiently ([e857652](https://github.com/Sycatle/senior-mode/commit/e857652b04e742f7c3a6f30cb9cca74e86239f12))
* **bin:** stop setup when a Project command fails ([9179b52](https://github.com/Sycatle/senior-mode/commit/9179b52b57944a35d506f7763958a79a27c5cf03))
* **bin:** swap a reused ticket's type label and document several fields ([16045bb](https://github.com/Sycatle/senior-mode/commit/16045bb878c928bf35b4b73dda8344eeda033df0))
* **check:** keep git's hook environment out of the checks ([5c5233f](https://github.com/Sycatle/senior-mode/commit/5c5233ffe1dbd2e5918fb29206590f0266e2e4ed)), refs [#46](https://github.com/Sycatle/senior-mode/issues/46)
* **frame:** accept docs/ reached through a symlinked project path ([74a2fd9](https://github.com/Sycatle/senior-mode/commit/74a2fd903f14a531c6a9a56a2f3ce604a6af2090))
* **frame:** hold subagents to docs/ too and leave the exit to the user ([2b471ae](https://github.com/Sycatle/senior-mode/commit/2b471ae8f09227ec20b26938ca84d9698bb06546))
* **frame:** read GitHub facts directly and wait for the merged spec ([7e4eaca](https://github.com/Sycatle/senior-mode/commit/7e4eaca3078afcd7ab53eadca947bce0695f47de))
* **frame:** refuse edits outside docs/ while framing ([42bbc1d](https://github.com/Sycatle/senior-mode/commit/42bbc1d62b2e71a7acc7c80e0d62b2306d795bc6)), refs [#36](https://github.com/Sycatle/senior-mode/issues/36)
* **frame:** reopen closed milestones and keep Ready behind the merged spec ([411a68f](https://github.com/Sycatle/senior-mode/commit/411a68f9f210f336a129e3d119c3fd39dbb3fb54))
* **frame:** reopen only chosen milestones and check Ready on GitHub ([a6c4aec](https://github.com/Sycatle/senior-mode/commit/a6c4aec837e7791cc4b3db51a045552087170054))
* **hooks:** catch admin merges split over lines or sent through the API ([7d0e3b8](https://github.com/Sycatle/senior-mode/commit/7d0e3b8fc2a9efe7d350c4a2ca7196675b2a2631))
* **hooks:** deny gh pr merge --admin to agents ([5a6ebf6](https://github.com/Sycatle/senior-mode/commit/5a6ebf6b84e97bb4c3173a8a9534a1e8ec0c3e5e)), refs [#30](https://github.com/Sycatle/senior-mode/issues/30)
* **hooks:** read quoted single words as plain arguments ([970fb0c](https://github.com/Sycatle/senior-mode/commit/970fb0cd5edadc51859c6e0382f9410b222dcf9a))
* **presets:** fall back to tsc only when typescript is installed ([67259c2](https://github.com/Sycatle/senior-mode/commit/67259c291203de7788bc4f39d3c4e5d40235f840))
* **setup:** bump a package.json version instead of releasing it again ([3a10df1](https://github.com/Sycatle/senior-mode/commit/3a10df15f3a37034e9aeb85ba18f7cc42dcf3b12)), refs [#45](https://github.com/Sycatle/senior-mode/issues/45)
* **setup:** never let the typecheck fallback download a package ([54cf01a](https://github.com/Sycatle/senior-mode/commit/54cf01a1a30d9cdaf18ff36e063074864cbc3a9e)), refs [#42](https://github.com/Sycatle/senior-mode/issues/42)
* **setup:** start adopted projects at 0.1.0 instead of 1.0.0 ([8f52824](https://github.com/Sycatle/senior-mode/commit/8f52824c110fe1d5c7d9bcbd97768e26b682a2ec)), refs [#41](https://github.com/Sycatle/senior-mode/issues/41)
