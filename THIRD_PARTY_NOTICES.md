# Third-Party Notices

The MIT License in this repository applies to the original Wilds of Kanto
source code and original project assets.

Third-party assets remain subject to their respective licenses and are not
relicensed under the Wilds of Kanto MIT License.

See the asset-specific documentation and credits for details.

## Notable third-party material

- Follow-sprite / overworld Pokemon art under `assets/enhanced_overworld/`
  remains under the license of its original authors and sources. It is not
  covered by this project's MIT License.
- Generated runtime sheets under `assets/generated/followsprites_runtime/`
  are derived from those third-party follow-sprites and inherit the same
  third-party licensing constraints. In the mod menu these are labeled
  **PokeMMO** (Wilds of Kanto's built-in style).
- Optional companion sprites from
  [Followers EX](https://github.com/masterwebx/gen1recomp-followers-ex)
  / [PokePC Followers](https://github.com/gamecorner-033/PokePCFollowers)
  remain owned by those projects. Wilds only consumes them through a runtime
  provider when installed; it does not redistribute those assets.
- Selection, fingerprint, talk, and single-follower lifecycle **concepts**
  adapted from PokéPC Followers (gamecorner-033) and Followers EX (masterwebx)
  are implemented under `lib/follower/` in this repository. Upstream assets
  are not copied. See `docs/analysis/FOLLOWER_INTEGRATION_PR1.md`.
- TRW / DAX and other original authors named in upstream follower credits
  remain credited there; Wilds does not relicense their work.
- Optional battle-front art from
  [Gold Sprites](https://github.com/OtaconRevengeance/gold_sprites)
  (`Gold_Silver_Sprites` by OtaconRevengeance) is likewise read-only at runtime
  and is not redistributed by Wilds. That release ships without a LICENSE file
  and asks users not to reupload the pack.
- Legacy Pokédex / battle art references used as fallbacks are game-adjacent
  assets and are not relicensed under MIT.
- Gen1Recomp engine APIs and Dramatic Shape Voxel Mod contracts belong to
  their respective projects and licenses.
