import Foundation

public struct Attribution: Sendable, Equatable, Identifiable {
    public let id: String            // "parakeet", "community-1", "fluidaudio"
    public let name: String
    public let licence: String       // "CC-BY-4.0", "Apache-2.0"
    public let url: String
    public let notes: String         // e.g. "Converted to Core ML by FluidInference. Used unmodified otherwise."
    public let licenceText: String?  // full text for Apache-2.0
    public init(id: String, name: String, licence: String, url: String, notes: String, licenceText: String?) {
        self.id = id; self.name = name; self.licence = licence; self.url = url; self.notes = notes; self.licenceText = licenceText
    }
}
public enum Attributions {
    /// Everything the app ships that needs crediting, in display order.
    /// CC-BY-4.0 requires credit, a link to the licence and a note of any changes; Apache-2.0 requires the licence text.
    public static let all: [Attribution] = [
        Attribution(
            id: "parakeet",
            name: "NVIDIA Parakeet TDT 0.6B v3",
            licence: "CC-BY-4.0",
            url: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            notes: "Speech recognition model by NVIDIA. Converted to Core ML by FluidInference; used unmodified otherwise. "
                + "Licensed under Creative Commons Attribution 4.0 International.",
            licenceText: nil),
        Attribution(
            id: "community-1",
            name: "pyannote speaker-diarization-community-1",
            licence: "CC-BY-4.0",
            url: "https://huggingface.co/pyannote/speaker-diarization-community-1",
            // The app ships these files (BundledModels/speaker-diarization), so the credit follows the NOTICE.md of the
            // exact repo commit in scripts/models.lock: pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference, the
            // README's citations, and a statement that the files are modified Core ML conversions.
            notes: "Speaker separation pipeline by pyannote (segmentation: Plaquet and Bredin, Interspeech 2023), "
                + "including the WeSpeaker ResNet34 voice embedding model (Wang et al., ICASSP 2023) and PLDA parameters "
                + "by Brno University of Technology / BUT Speech@FIT (VBx clustering: Landini et al., Computer Speech & Language 2022). "
                + "Converted to Core ML by FluidInference (Fluid Inference); these are modified files: fixed and enumerated "
                + "input shapes, mixed-precision storage, and the FBank frontend separated from the embedding backend. "
                + "From https://huggingface.co/FluidInference/speaker-diarization-coreml; notice: "
                + "https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/NOTICE.md. "
                + "Licensed under Creative Commons Attribution 4.0 International.",
            licenceText: nil),
        Attribution(
            id: "nemotron-3-diarization",
            name: "NVIDIA Nemotron 3 Diarization",
            licence: "OpenMDW-1.1",
            url: "https://huggingface.co/nvidia/Nemotron-3-Diarization",
            notes: "Speaker diarization model by NVIDIA; decides who speaks when, for up to eight speakers. "
                + "Converted to Core ML by Fluid Inference (fast128 preset, 16-bit floating point), "
                + "from https://huggingface.co/FluidInference/nemotron-3-diarization-coreml; used unmodified otherwise. "
                + "Licensed under the OpenMDW License Agreement, version 1.1.",
            licenceText: openMDW11Text),
        Attribution(
            id: "fluidaudio",
            name: "FluidAudio",
            licence: "Apache-2.0",
            url: "https://github.com/FluidInference/FluidAudio",
            notes: "On-device speech recognition and speaker separation library by FluidInference (version 0.18.4).",
            licenceText: apache20Text),
    ]
    /// Ids that must be present (tested).
    public static let requiredIDs: Set<String> = ["parakeet", "community-1", "nemotron-3-diarization", "fluidaudio"]

    /// Creative Commons Attribution 4.0 International legal code.
    public static let ccBy40URL = "https://creativecommons.org/licenses/by/4.0/"
    /// Apache License 2.0 on apache.org.
    public static let apache20URL = "https://www.apache.org/licenses/LICENSE-2.0"
    /// OpenMDW License Agreement 1.1 (Linux Foundation).
    public static let openMDW11URL = "https://openmdw.ai/license/1-1/"

    /// Licences whose full text must ship with the app (Apache-2.0 §4(a); OpenMDW-1.1 "retain a copy of this agreement").
    public static let fullTextLicences: Set<String> = ["Apache-2.0", "OpenMDW-1.1"]

    /// Where the licence itself can be read, for the "Licence" link next to each entry.
    public static func licenceURL(for licence: String) -> String? {
        switch licence {
        case "CC-BY-4.0": ccBy40URL
        case "Apache-2.0": apache20URL
        case "OpenMDW-1.1": openMDW11URL
        default: nil
        }
    }

    /// OpenMDW License Agreement, version 1.1, verbatim (https://openmdw.ai/license/1-1/, checked 2026-11-23).
    public static let openMDW11Text: String = #"""
OpenMDW License Agreement, version 1.1 (OpenMDW-1.1)

By exercising rights granted to you under this agreement, you accept and agree to its terms.

As used in this agreement, “Model Materials” means the materials provided to you under this agreement, consisting of: (1) one or more machine learning models (including architecture and parameters); and (2) all related artifacts (including associated data, documentation and software) that are provided to you hereunder.

Subject to your compliance with this agreement, permission is hereby granted, free of charge, to deal in the Model Materials without restriction, including under all copyright, patent, database, and trade secret rights included or embodied therein.

If you distribute any portion of the Model Materials, you shall retain in your distribution (1) a copy of this agreement, and (2) all copyright notices and other notices of origin included in the Model Materials that are applicable to your distribution.

If you file, maintain, or voluntarily participate in a lawsuit against any person or entity asserting that the Model Materials directly or indirectly infringe any patent or copyright, then all rights and grants made to you hereunder are terminated, unless that lawsuit was in response to a corresponding lawsuit first brought against you.

This agreement does not impose any restrictions or obligations with respect to any use, modification, or sharing of any outputs generated by using the Model Materials.

THE MODEL MATERIALS ARE PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, NONINFRINGEMENT, ACCURACY, OR THE ABSENCE OF LATENT OR OTHER DEFECTS OR ERRORS, WHETHER OR NOT DISCOVERABLE, ALL TO THE GREATEST EXTENT PERMISSIBLE UNDER APPLICABLE LAW.

YOU ARE SOLELY RESPONSIBLE FOR (1) CLEARING RIGHTS OF OTHER PERSONS THAT MAY APPLY TO THE MODEL MATERIALS OR ANY USE THEREOF, INCLUDING WITHOUT LIMITATION ANY PERSON’S COPYRIGHTS OR OTHER RIGHTS INCLUDED OR EMBODIED IN THE MODEL MATERIALS; (2) OBTAINING ANY NECESSARY CONSENTS, PERMISSIONS OR OTHER RIGHTS REQUIRED FOR ANY USE OF THE MODEL MATERIALS; OR (3) PERFORMING ANY DUE DILIGENCE OR UNDERTAKING ANY OTHER INVESTIGATIONS INTO THE MODEL MATERIALS OR ANYTHING INCORPORATED OR EMBODIED THEREIN.

IN NO EVENT SHALL THE PROVIDERS OF THE MODEL MATERIALS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE MODEL MATERIALS, THE USE THEREOF OR OTHER DEALINGS THEREIN.
"""#

    /// Apache License 2.0, verbatim (as distributed with FluidAudio).
    public static let apache20Text: String = #"""
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
"""#
}
