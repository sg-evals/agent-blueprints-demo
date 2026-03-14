/**
 * LLM client for generating investigation summaries.
 * In demo mode, returns deterministic template-based output.
 */

export interface LLMConfig {
  apiKey: string;
  model: string;
  demoMode: boolean;
}

export interface InvestigationContext {
  failingTest: string;
  errorMessage: string;
  relevantFiles: { path: string; content?: string }[];
  deepSearchSummary: string;
  symbolDefinitions: string[];
}

export interface InvestigationSummary {
  rootCause: string;
  relevantFiles: string[];
  suggestedFix: string;
  confidence: 'high' | 'medium' | 'low';
}

export class LLMClient {
  private config: LLMConfig;

  constructor(config: LLMConfig) {
    this.config = config;
  }

  /** Generate an investigation summary from context. */
  async investigate(context: InvestigationContext): Promise<InvestigationSummary> {
    if (this.config.demoMode) {
      return this.demoInvestigation(context);
    }
    return this.liveInvestigation(context);
  }

  /** Deterministic demo-mode investigation. */
  private demoInvestigation(context: InvestigationContext): InvestigationSummary {
    // Template-based output for deterministic demo
    return {
      rootCause: `${context.failingTest} fails because the backoff calculation produces a negative duration. ` +
        `The function \`RetryBackoff\` in \`libs/retry/backoff.go\` was simplified from exponential to linear ` +
        `backoff using \`(attempt-1) * baseDelay\`, but the attempt-clamping guard (\`if attempt < 1\`) was removed. ` +
        `When \`attempt=0\`, the formula yields \`-1 * baseDelay = -100ms\`.`,
      relevantFiles: context.relevantFiles.map(f => f.path),
      suggestedFix: 'Restore the attempt clamp: `if attempt < 1 { attempt = 1 }` before the delay calculation, ' +
        'or switch back to exponential backoff which naturally handles this case.',
      confidence: 'medium',
    };
  }

  /** Live LLM-based investigation using Claude API. */
  private async liveInvestigation(context: InvestigationContext): Promise<InvestigationSummary> {
    const prompt = this.buildPrompt(context);

    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': this.config.apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: this.config.model,
        max_tokens: 1024,
        messages: [{ role: 'user', content: prompt }],
      }),
    });

    if (!resp.ok) {
      console.error('LLM API error, falling back to demo mode');
      return this.demoInvestigation(context);
    }

    const data = await resp.json() as { content: { text: string }[] };
    return this.parseLLMResponse(data.content[0]?.text ?? '', context);
  }

  private buildPrompt(context: InvestigationContext): string {
    return `You are investigating a CI test failure.

Failing test: ${context.failingTest}
Error: ${context.errorMessage}

Deep Search findings:
${context.deepSearchSummary}

Relevant files:
${context.relevantFiles.map(f => `- ${f.path}`).join('\n')}

Symbol definitions:
${context.symbolDefinitions.join('\n')}

Provide a JSON response with: rootCause, relevantFiles (array), suggestedFix, confidence (high/medium/low).`;
  }

  private parseLLMResponse(text: string, context: InvestigationContext): InvestigationSummary {
    try {
      const parsed = JSON.parse(text);
      return {
        rootCause: parsed.rootCause ?? 'Unable to determine',
        relevantFiles: parsed.relevantFiles ?? context.relevantFiles.map(f => f.path),
        suggestedFix: parsed.suggestedFix ?? 'Manual investigation required',
        confidence: parsed.confidence ?? 'low',
      };
    } catch {
      // Fallback to demo if parsing fails
      return this.demoInvestigation(context);
    }
  }
}
