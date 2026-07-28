package com.example.rhtas;

import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ResponseBody;

@Controller
public class BuildInfoController {

    @Value("${app.build.version:unknown}")
    private String buildVersion;

    @Value("${app.image.digest:unknown}")
    private String imageDigest;

    @Value("${app.image.ref:unknown}")
    private String imageRef;

    @Value("${app.signer.identity:unknown}")
    private String signerIdentity;

    @Value("${app.signed.at:unknown}")
    private String signedAt;

    @Value("${app.scenario:unknown}")
    private String scenario;

    @Value("${app.fulcio.url:unknown}")
    private String fulcioUrl;

    @Value("${app.rekor.url:unknown}")
    private String rekorUrl;

    @Value("${app.oidc.issuer:unknown}")
    private String oidcIssuer;

    @Value("${app.git.commit:unknown}")
    private String gitCommit;

    @Value("${app.builder.image:unknown}")
    private String builderImage;

    @Value("${app.runtime.image:unknown}")
    private String runtimeImage;

    @Value("${app.tuf.url:unknown}")
    private String tufUrl;

    @Value("${app.cosign.image:registry.redhat.io/rhtas/cosign-rhel9}")
    private String cosignImage;

    @GetMapping("/")
    public String page(Model model) {
        boolean signed = isSigned(signerIdentity);
        model.addAttribute("title", "RHTAS Cosign Trust Report");
        model.addAttribute("scenario", scenario);
        model.addAttribute("buildVersion", buildVersion);
        model.addAttribute("imageRef", imageRef);
        model.addAttribute("imageDigest", imageDigest);
        model.addAttribute("signerIdentity", signerIdentity);
        model.addAttribute("signedAt", signedAt);
        model.addAttribute("fulcioUrl", fulcioUrl);
        model.addAttribute("rekorUrl", rekorUrl);
        model.addAttribute("oidcIssuer", oidcIssuer);
        model.addAttribute("gitCommit", gitCommit);
        model.addAttribute("builderImage", builderImage);
        model.addAttribute("runtimeImage", runtimeImage);
        model.addAttribute("tufUrl", tufUrl);
        model.addAttribute("cosignImage", cosignImage);
        model.addAttribute("signed", signed);
        model.addAttribute("statusLabel", signed ? "Keyless signature present" : "Unsigned / not yet signed");
        model.addAttribute("verifyCommand", verifyCommand());
        model.addAttribute("verifyCommandPodman", verifyCommandPodman());
        return "trust";
    }

    @GetMapping("/api/info")
    @ResponseBody
    public Map<String, Object> info() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("message", "Hello from RHTAS demo");
        body.put("scenario", scenario);
        body.put("buildVersion", buildVersion);
        body.put("imageRef", imageRef);
        body.put("imageDigest", imageDigest);
        body.put("signerIdentity", signerIdentity);
        body.put("signedAt", signedAt);
        body.put("fulcioUrl", fulcioUrl);
        body.put("rekorUrl", rekorUrl);
        body.put("oidcIssuer", oidcIssuer);
        body.put("gitCommit", gitCommit);
        body.put("builderImage", builderImage);
        body.put("runtimeImage", runtimeImage);
        body.put("tufUrl", tufUrl);
        body.put("cosignImage", cosignImage);
        body.put("signed", isSigned(signerIdentity));
        body.put("verifyCommand", verifyCommand());
        body.put("verifyCommandPodman", verifyCommandPodman());
        return body;
    }

    private static boolean isSigned(String identity) {
        return identity != null
                && !identity.isBlank()
                && !"unsigned".equalsIgnoreCase(identity)
                && !"unknown".equalsIgnoreCase(identity);
    }

    private String verifyImage() {
        if (imageRef != null && !imageRef.isBlank() && !"unknown".equals(imageRef)) {
            return imageRef;
        }
        return "<image-ref>";
    }

    private String verifyIdentity() {
        return isSigned(signerIdentity) ? signerIdentity : "<certificate-identity>";
    }

    private String verifyIssuer() {
        if (oidcIssuer != null && !oidcIssuer.isBlank() && !"unknown".equals(oidcIssuer)) {
            return oidcIssuer;
        }
        return "<oidc-issuer>";
    }

    private String verifyTuf() {
        if (tufUrl != null && !tufUrl.isBlank() && !"unknown".equals(tufUrl)) {
            return tufUrl;
        }
        return "<tuf-url>";
    }

    private String verifyCommand() {
        return "cosign verify \\\n"
                + "  --certificate-identity='" + verifyIdentity() + "' \\\n"
                + "  --certificate-oidc-issuer='" + verifyIssuer() + "' \\\n"
                + "  " + verifyImage();
    }

    private String verifyCommandPodman() {
        String tuf = verifyTuf();
        String image = (cosignImage != null && !cosignImage.isBlank())
                ? cosignImage
                : "registry.redhat.io/rhtas/cosign-rhel9";
        return "podman run --rm -it \\\n"
                + "  -e COSIGN_YES=true \\\n"
                + "  " + image + " \\\n"
                + "  sh -c \"\n"
                + "    cosign initialize --mirror '" + tuf + "' --root '" + tuf + "/root.json' &&\n"
                + "    cosign verify \\\n"
                + "      --certificate-identity='" + verifyIdentity() + "' \\\n"
                + "      --certificate-oidc-issuer='" + verifyIssuer() + "' \\\n"
                + "      " + verifyImage() + "\n"
                + "  \"";
    }
}
