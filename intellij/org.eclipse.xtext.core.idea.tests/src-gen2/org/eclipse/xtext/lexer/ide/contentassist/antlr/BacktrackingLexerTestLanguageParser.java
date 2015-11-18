/*
 * generated by Xtext
 */
package org.eclipse.xtext.lexer.ide.contentassist.antlr;

import com.google.inject.Inject;
import java.util.Collection;
import java.util.HashMap;
import java.util.Map;
import org.antlr.runtime.RecognitionException;
import org.eclipse.xtext.AbstractElement;
import org.eclipse.xtext.ide.editor.contentassist.antlr.AbstractContentAssistParser;
import org.eclipse.xtext.ide.editor.contentassist.antlr.FollowElement;
import org.eclipse.xtext.ide.editor.contentassist.antlr.internal.AbstractInternalContentAssistParser;
import org.eclipse.xtext.lexer.ide.contentassist.antlr.internal.InternalBacktrackingLexerTestLanguageParser;
import org.eclipse.xtext.lexer.services.BacktrackingLexerTestLanguageGrammarAccess;

public class BacktrackingLexerTestLanguageParser extends AbstractContentAssistParser {

	@Inject
	private BacktrackingLexerTestLanguageGrammarAccess grammarAccess;

	private Map<AbstractElement, String> nameMappings;

	@Override
	protected InternalBacktrackingLexerTestLanguageParser createParser() {
		InternalBacktrackingLexerTestLanguageParser result = new InternalBacktrackingLexerTestLanguageParser(null);
		result.setGrammarAccess(grammarAccess);
		return result;
	}

	@Override
	protected String getRuleName(AbstractElement element) {
		if (nameMappings == null) {
			nameMappings = new HashMap<AbstractElement, String>() {
				private static final long serialVersionUID = 1L;
				{
					put(grammarAccess.getEnumNameAccess().getAlternatives(), "rule__EnumName__Alternatives");
					put(grammarAccess.getModelAccess().getGroup(), "rule__Model__Group__0");
					put(grammarAccess.getAbAccess().getGroup(), "rule__Ab__Group__0");
					put(grammarAccess.getXbAccess().getGroup(), "rule__Xb__Group__0");
					put(grammarAccess.getModelAccess().getEnumsAssignment_0(), "rule__Model__EnumsAssignment_0");
					put(grammarAccess.getModelAccess().getYcsAssignment_1(), "rule__Model__YcsAssignment_1");
					put(grammarAccess.getModelAccess().getAbsAssignment_2(), "rule__Model__AbsAssignment_2");
					put(grammarAccess.getModelAccess().getXbsAssignment_3(), "rule__Model__XbsAssignment_3");
					put(grammarAccess.getModelAccess().getYsAssignment_4(), "rule__Model__YsAssignment_4");
					put(grammarAccess.getModelAccess().getAsAssignment_5(), "rule__Model__AsAssignment_5");
					put(grammarAccess.getAbAccess().getXAssignment_0(), "rule__Ab__XAssignment_0");
					put(grammarAccess.getAbAccess().getYAssignment_1(), "rule__Ab__YAssignment_1");
					put(grammarAccess.getXbAccess().getXAssignment_0(), "rule__Xb__XAssignment_0");
					put(grammarAccess.getXbAccess().getYAssignment_1(), "rule__Xb__YAssignment_1");
				}
			};
		}
		return nameMappings.get(element);
	}

	@Override
	protected Collection<FollowElement> getFollowElements(AbstractInternalContentAssistParser parser) {
		try {
			InternalBacktrackingLexerTestLanguageParser typedParser = (InternalBacktrackingLexerTestLanguageParser) parser;
			typedParser.entryRuleModel();
			return typedParser.getFollowElements();
		} catch(RecognitionException ex) {
			throw new RuntimeException(ex);
		}
	}

	@Override
	protected String[] getInitialHiddenTokens() {
		return new String[] { "RULE_WS", "RULE_SL_COMMENT" };
	}

	public BacktrackingLexerTestLanguageGrammarAccess getGrammarAccess() {
		return this.grammarAccess;
	}

	public void setGrammarAccess(BacktrackingLexerTestLanguageGrammarAccess grammarAccess) {
		this.grammarAccess = grammarAccess;
	}
}
