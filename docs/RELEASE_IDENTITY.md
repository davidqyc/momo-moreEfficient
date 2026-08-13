# Release identity

This file records the project-specific Apple distribution identity and OSS/distribution boundary.

## Canonical project home

- Canonical public project home: `https://github.com/davidqyc/momo-moreEfficient`
- GitHub is the canonical source/project/issue/release home for the open-source project.
- TestFlight / App Store are product distribution channels, not the canonical project authority.
- App Store marketing URL may point to the GitHub repository.
- Support/privacy may remain zero-cost public GitHub pages/files as long as Apple requirements are met.

## Apple distribution identity

- Legal organization: `Awaiting Aesthetic Living Arts (Shenyang) Co., Ltd.`
- Paid Apple Developer Program / App Store Connect Team ID: `W26LH686PD`
- The organization's Account Holder/Admin account owns App Store Connect distribution authority.
- Xcode `Personal Team` is local-development-only and must not be inferred or reused as the TestFlight/App Store distribution team.
- Historical personal-team signing used `com.davidqyc.momoMoreEfficient`; that Bundle ID is not available for registration under the organization team and is not the release Bundle ID.
- Final release Bundle ID: `com.jiripple.xiaoheiniao`
- Registered organization App ID description: `XiaoHeiNiaoCompanion`
- App Store Connect app name: `小黑鸟伴侣`
- App Store Connect record exists for iOS 1.0 under the organization team.

## Release rule

Before any TestFlight/App Store archive or upload:

1. verify the Xcode target Bundle ID exactly matches `com.jiripple.xiaoheiniao`;
2. verify signing resolves to organization Team `W26LH686PD`, not Personal Team;
3. verify the App Store Connect record exists for the same Bundle ID;
4. only then archive/upload through the normal App Store Connect/TestFlight path.

Do not create Fastlane/Xcode Cloud/API-key release infrastructure solely for the first cohort.

## OSS identity rule

The GitHub repository remains the canonical open-source project identity even though the iOS binary is distributed by the organization account. Apple distribution ownership and GitHub maintainer identity are separate concerns. External adoption through TestFlight/App Store is supporting evidence for OSS usage; GitHub remains the primary maintainer/source authority.
