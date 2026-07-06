package com.example.rhtas;

import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class BuildInfoController {

    @Value("${app.build.version:unknown}")
    private String buildVersion;

    @Value("${app.image.digest:unknown}")
    private String imageDigest;

    @Value("${app.signer.identity:unknown}")
    private String signerIdentity;

    @Value("${app.signed.at:unknown}")
    private String signedAt;

    @Value("${app.scenario:unknown}")
    private String scenario;

    @GetMapping("/")
    public Map<String, Object> hello() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("message", "Hello from RHTAS demo");
        body.put("scenario", scenario);
        body.put("buildVersion", buildVersion);
        body.put("imageDigest", imageDigest);
        body.put("signerIdentity", signerIdentity);
        body.put("signedAt", signedAt);
        return body;
    }

    @GetMapping("/api/info")
    public Map<String, Object> info() {
        return hello();
    }
}
